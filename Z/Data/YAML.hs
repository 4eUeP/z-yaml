{-|
Module      : Z.Data.YAML.FFI
Description : LibYAML bindings
Copyright   : (c) Dong Han, 2020
License     : BSD
Maintainer  : winterland1989@gmail.com
Stability   : experimental
Portability : non-portable

Simple YAML codec using <https://libyaml.docsforge.com/ libYAML> and JSON's 'FromValue' \/ 'ToValue' utilities.
The design choice to make things as simple as possible since YAML is a complex format, there're some limitations using this approach:

* Does not support complex keys.
* Dose not support multiple doucments in one file.

@
{-# LANGUAGE DeriveGeneric, DeriveAnyClass, DerivingStrategies, TypeApplication #-}

import           GHC.Generics
import qualified Z.Data.YAML as YAML
import qualified Z.Data.Text as T

data Person = Person
    { name  :: T.Text
    , age   :: Int
    , magic :: Bool
    }
  deriving (Show, Generic)
  deriving anyclass (FromValue, ToValue)

> YAML.decode @[Person] "- name: Erik Weisz\n  age: 52\n  magic: True\n"
> Right [Person {name = "Erik Weisz", age = 52, magic = True}]
@

-}


module Z.Data.YAML
  ( -- * decode and encode using YAML
    decodeFromFile
  , decodeValueFromFile
  , decode
  , decodeValue
  , encodeToFile
  , encodeValueToFile
  , encode
  , encodeValue
  , YAMLParseError(..)
  , YAMLParseException(..)
  -- * streaming parser and builder
  , parseSingleDoucment
  , parseAllDocuments
  , buildSingleDocument
  , buildValue
  -- * re-exports
  , FromValue(..)
  , ToValue(..)
  , Value(..)
  ) where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Bits              ((.|.), unsafeShiftL)
import           Data.IORef
import qualified Data.HashMap.Strict as HM
import qualified Data.HashSet        as HS
import qualified Data.Scientific as Sci
import qualified Z.Data.Parser as P
import qualified Z.Data.Vector as V
import qualified Z.Data.Text   as T
import           Z.Data.JSON            (FromValue(..), ToValue(..), Value(..), ConvertError, convert')
import           Z.Data.YAML.FFI
import           Control.Monad.Trans.Reader
import qualified Z.Data.Vector.FlatMap as FM
import qualified Z.Data.Builder as B
import           Z.Data.CBytes          (CBytes)
import           Z.Data.YAML.FFI
import           Z.IO
import           System.IO.Unsafe

-- | Decode a 'FromValue' instance from file.
decodeFromFile :: (HasCallStack, FromValue a) => CBytes -> IO a
decodeFromFile p = withResource (initFileParser p) $ \ src -> do
    r <- convert' <$> parseSingleDoucment src
    case r of Left e -> throwIO (YAMLConvertException e callStack)
              Right v -> return v

-- | Decode a 'Value' from file.
decodeValueFromFile :: HasCallStack => CBytes -> IO Value
decodeValueFromFile p = withResource (initFileParser p) parseSingleDoucment

-- | Decode a 'FromValue' instance from bytes.
decode :: FromValue a => V.Bytes -> Either YAMLParseException a
decode bs = unsafePerformIO . try . withResource (initParser bs) $ \ src -> do
    r <- convert' <$> parseSingleDoucment src
    case r of Left e -> throwIO (YAMLConvertException e callStack)
              Right v -> return v

-- | Decode a 'Value' from bytes.
decodeValue :: V.Bytes -> Either YAMLParseException Value
decodeValue bs = unsafePerformIO . try $ withResource (initParser bs) parseSingleDoucment

-- | Encode a 'ToValue' instance to file.
encodeToFile :: (HasCallStack, ToValue a) => YAMLFormatOpts -> CBytes -> a -> IO ()
encodeToFile opts p x = withResource (initFileEmitter opts p) $ \ sink ->
    buildSingleDocument sink (toValue x)

-- | Encode a 'Value' to file.
encodeValueToFile :: HasCallStack => YAMLFormatOpts -> CBytes -> Value -> IO ()
encodeValueToFile opts p v = withResource (initFileEmitter opts p) $ \ sink ->
    buildSingleDocument sink v

-- | Encode a 'ToValue' instance as UTF8 text.
encode :: (HasCallStack, ToValue a) => YAMLFormatOpts -> a -> T.Text
encode opts x = unsafePerformIO . withResource (initEmitter opts) $ \ (p, sink) -> do
    buildSingleDocument sink (toValue x)
    getEmitterResult p

-- | Encode a 'Value' as UTF8 text.
encodeValue :: HasCallStack => YAMLFormatOpts -> Value -> T.Text
encodeValue opts v = unsafePerformIO . withResource (initEmitter opts) $ \ (p, sink) -> do
    buildSingleDocument sink v
    getEmitterResult p

--------------------------------------------------------------------------------

data YAMLParseError
    = UnknownAlias Mark Mark Anchor
    | UnexpectedEvent MarkedEvent
    | NonStringKey Mark Mark T.Text
    | NonStringKeyAlias Mark Mark Anchor
    | UnexpectedEventEnd
  deriving (Show, Eq)

instance Exception YAMLParseError

data YAMLParseException
    = YAMLParseException YAMLParseError CallStack
    | YAMLConvertException ConvertError CallStack
    | MultipleDocuments CallStack
  deriving Show

instance Exception YAMLParseException

parseSingleDoucment :: HasCallStack => Source MarkedEvent -> IO Value
parseSingleDoucment src = do
    docs <- parseAllDocuments src
    case docs of
        [] -> return Null
        [doc] -> return doc
        _ -> throwIO (MultipleDocuments callStack)

parseAllDocuments :: HasCallStack => Source MarkedEvent -> IO [Value]
parseAllDocuments src = do
    me <- pull src
    case me of
        Just (MarkedEvent EventStreamStart _ _) -> do
            as <- newIORef HM.empty
            catch (runReaderT parseDocs (src, as)) $ \ (e :: YAMLParseError) ->
                throwIO (YAMLParseException e callStack)
        Just me' -> throwIO (YAMLParseException (UnexpectedEvent me') callStack)
        -- empty file input, comment only string/file input
        _ -> return []
  where
    parseDocs = do
        me <- pullEvent
        case me of
            MarkedEvent EventStreamEnd _ _      -> return []
            MarkedEvent EventDocumentStart _ _  -> do
                res <- parseValue =<< pullEvent
                me' <- pullEvent
                case me' of
                    MarkedEvent EventDocumentEnd _ _ ->
                        (res :) <$> parseDocs
                    me'' -> throwParserIO (UnexpectedEvent me'')


type ParserIO = ReaderT (Source MarkedEvent, IORef (HM.HashMap T.Text Value)) IO

pullEvent :: ParserIO MarkedEvent
pullEvent = do
    (src, _) <- ask
    liftIO $ do
        me <- pull src
        case me of Just e -> return e
                   _ -> throwIO UnexpectedEventEnd

throwParserIO :: YAMLParseError -> ParserIO a
throwParserIO = liftIO . throwIO

defineAnchor :: T.Text -> Value -> ParserIO ()
defineAnchor key value = unless (T.null key) $ do
    (_, mref) <- ask
    liftIO $ modifyIORef' mref (HM.insert key value)

lookupAlias :: Mark -> Mark -> T.Text -> ParserIO Value
lookupAlias startMark endMark key = do
    (_, mref) <- ask
    liftIO $ do
        m <- readIORef mref
        case HM.lookup key m of
            Just v -> return v
            _ -> throwIO (UnknownAlias startMark endMark key)

textToValue :: ScalarStyle -> Tag -> T.Text -> Value
textToValue SingleQuoted _ t = String t
textToValue DoubleQuoted _ t = String t
textToValue _ StrTag t       = String t
textToValue Folded _ t       = String t
textToValue _ _ t
    | t `elem` ["null", "Null", "NULL", "~", ""] = Null
    | t `elem` ["y", "Y", "yes", "on", "true", "YES", "ON", "TRUE", "Yes", "On", "True"]    = Bool True
    | t `elem` ["n", "N", "no", "off", "false", "NO", "OFF", "FALSE", "No", "Off", "False"] = Bool False
    | Right x <- textToScientific t = Number x
    | otherwise = String t

textToScientific :: T.Text -> Either P.ParseError Sci.Scientific
textToScientific = P.parse' (num <* P.endOfInput) . T.getUTF8Bytes
  where
    num = (fromInteger <$> (P.bytes "0x" *> P.hex_ @Integer))
      <|> (fromInteger <$> (P.bytes "0o" *> octal))
      <|> P.scientific

    octal = V.foldl' step 0 <$> P.takeWhile1 (\ w -> w >= B.ZERO && w < B.ZERO+8)
    step a c = (a `unsafeShiftL` 3) .|. fromIntegral (c - B.ZERO)

parseValue :: MarkedEvent -> ParserIO Value
parseValue me@(MarkedEvent e startMark endMark) =
    case e of
        EventScalar anchor v tag style -> do
            let !v' = textToValue style tag v
            defineAnchor anchor v'
            return v'
        EventSequenceStart anchor _ _  -> do
            !v <- parseSequence
            defineAnchor anchor v
            return v
        EventMappingStart anchor _ _   -> do
            !v <- parseMapping
            defineAnchor anchor v
            return v
        EventAlias anchor              -> lookupAlias startMark endMark anchor
        _ -> throwParserIO (UnexpectedEvent me)

parseSequence :: ParserIO Value
parseSequence = Array . V.packR <$> go []
  where
    go acc = do
        e <- pullEvent
        case e of
            MarkedEvent EventSequenceEnd _ _ -> return acc
            _ -> do
                o <- parseValue e
                go (o:acc)

parseMapping :: ParserIO Value
parseMapping = Object . V.packR <$> go []
  where
    go acc = do
        me <- pullEvent
        case me of
            MarkedEvent EventMappingEnd _ _ -> return acc
            MarkedEvent e startMark endMark -> do
                key <- case e of
                    EventScalar anchor v tag style ->
                        case textToValue style tag v of
                            k@(String k') -> do
                                defineAnchor anchor k
                                return k'
                            _ -> throwParserIO (NonStringKey startMark endMark v)

                    EventAlias anchor -> do
                        m <- lookupAlias startMark endMark anchor
                        case m of
                            String k -> return k
                            _ -> throwParserIO (NonStringKeyAlias startMark endMark anchor)
                    e -> throwParserIO (UnexpectedEvent me)

                value <- parseValue =<< pullEvent

                -- overidding
                if key == "<<"
                then case value of
                    -- overide a mapping literal
                    Object kvs  -> go (V.unpackR kvs ++ acc)
                    -- overide a mapping list
                    Array vs -> go (V.foldr' mergeMapping acc vs)
                    v          ->  throwParserIO (UnexpectedEvent me)

                else go ((key, value):acc)

    -- ignore non-object
    mergeMapping  (Object o) acc = acc ++ V.unpackR o
    mergeMapping  v          acc = acc

--------------------------------------------------------------------------------

-- | Write a value as a YAML document stream.
--
-- @since 0.11.2.0
buildSingleDocument :: HasCallStack => Sink Event -> Value -> IO ()
buildSingleDocument sink v = do
    push sink EventStreamStart
    push sink EventDocumentStart
    buildValue sink v
    push sink EventDocumentEnd
    void $ push sink EventStreamEnd

-- | Write a value as a list of 'Event's(without document start\/end, stream start\/end).
--
-- @since 0.11.2.0
buildValue :: HasCallStack => Sink Event -> Value -> IO ()
buildValue sink (Array vs) = do
    push sink (EventSequenceStart "" NoTag AnySequence)
    mapM_ (buildValue sink) (V.unpack vs)
    void $ push sink EventSequenceEnd

buildValue sink (Object o) = do
    push sink (EventMappingStart "" NoTag AnyMapping)
    mapM_ encodeKV (V.unpack o)
    void $ push sink EventMappingEnd
  where
    encodeKV (k, v) = buildValue sink (String k) >> buildValue sink v

buildValue sink (String s) = void $ push sink (EventScalar "" s NoTag (stringStyle s))
  where
    stringStyle s
        | (_, Just _) <- (== '\n') `T.find` s   = Literal
        | isSpecialString s                     = SingleQuoted
        | otherwise                             = PlainNoTag

    isSpecialString s = s `HS.member` specialStrings || isNumeric s
    specialStrings = HS.fromList $ T.words
        "y Y yes Yes YES n N no No NO true True TRUE false False FALSE on On ON off Off OFF null Null NULL ~ *"
    isNumeric = either (const False) (const True) . textToScientific

buildValue sink Null         = void $ push sink (EventScalar "" "null" NullTag PlainNoTag)
buildValue sink (Bool True)  = void $ push sink (EventScalar "" "true" BoolTag PlainNoTag)
buildValue sink (Bool False) = void $ push sink (EventScalar "" "false" BoolTag PlainNoTag)
buildValue sink (Number s)   = do
    let builder
            -- Special case the 0 exponent to remove the trailing .0
            | Sci.base10Exponent s == 0 = B.integer $ Sci.coefficient s
            | otherwise = B.scientific s
        t = B.unsafeBuildText builder
    void $ push sink (EventScalar "" t IntTag PlainNoTag)

-- | Module dealing with HTTP: request data types, encoding and decoding...
{-# LANGUAGE DeriveDataTypeable, OverloadedStrings #-}
module Network.WebSockets.Http
    ( Headers
    , RequestHttpPart (..)
    , Request (..)
    , Response (..)
    , HandshakeError (..)
    , decodeRequest
    , encodeResponse
    ) where

import Data.Dynamic (Typeable)
import Data.Monoid (mappend, mconcat)
import Control.Applicative ((<$>), (<*>), (*>), (<*))
import Control.Exception (Exception)
import Control.Monad.Error (Error (..))

import Data.Attoparsec (string, takeWhile1, word8)
import Data.Attoparsec.Combinator (manyTill)
import Data.ByteString.Char8 ()
import Data.ByteString.Internal (c2w)
import qualified Blaze.ByteString.Builder as Builder
import qualified Blaze.ByteString.Builder.Char.Utf8 as Builder
import qualified Data.ByteString as B
import qualified Data.CaseInsensitive as CI

import Network.WebSockets.Types

-- | Request headers
type Headers = [(CI.CI B.ByteString, B.ByteString)]

-- | (internal) HTTP headers and requested path.
data RequestHttpPart = RequestHttpPart
    { requestHttpPath    :: !B.ByteString
    , requestHttpHeaders :: Headers
    } deriving (Eq, Show)

-- | Simple request type
data Request = Request
    { requestPath     :: !B.ByteString
    , requestHeaders  :: Headers
    , requestResponse :: Response
    }
    deriving (Show)

-- | Response to a 'Request'
data Response = Response
    { responseCode    :: !Int
    , responseMessage :: !B.ByteString
    , responseHeaders :: Headers
    , responseBody    :: B.ByteString
    } deriving (Show)

-- | Error in case of failed handshake. Will be thrown as an iteratee
-- exception. ('Error' condition).
--
-- TODO: This should probably be in the Handshake module, and is solely here to
-- prevent a cyclic dependency.
data HandshakeError =
      NotSupported                             -- ^ We don't have a match for the protocol requested by the client.
                                               -- todo: version parameter
    | MalformedRequest RequestHttpPart String  -- ^ The request was somehow invalid (missing headers or wrong security token)
    | RequestRejected  Request String          -- ^ The request was well-formed, but the library user rejected it.
                                               -- (e.g. "unknown path")
    | OtherHandshakeError String               -- ^ for example "EOF came too early" (which is actually a parse error)
                                               -- or for your own errors. (like "unknown path"?)
    deriving (Show, Typeable)

instance Error HandshakeError where
    strMsg = OtherHandshakeError

instance Exception HandshakeError

-- | Parse an initial request
decodeRequest :: Decoder p RequestHttpPart
decodeRequest = RequestHttpPart
    <$> requestLine
    <*> manyTill header newline
  where
    space = word8 (c2w ' ')
    newline = string "\r\n"

    requestLine = string "GET" *> space *> takeWhile1 (/= c2w ' ')
        <* space
        <* string "HTTP/1.1" <* newline

    header = (,)
        <$> (CI.mk <$> takeWhile1 (/= c2w ':'))
        <*  string ": "
        <*> takeWhile1 (/= c2w '\r')
        <*  newline

-- | Encode an HTTP upgrade response
encodeResponse :: Encoder p Response
encodeResponse _ (Response code msg headers body) =
    Builder.copyByteString "HTTP/1.1 " `mappend`
    Builder.fromString (show code)     `mappend`
    Builder.fromChar ' '               `mappend`
    Builder.fromByteString msg         `mappend`
    Builder.fromByteString "\r\n"      `mappend`
    mconcat (map header headers)       `mappend`
    Builder.copyByteString "\r\n"      `mappend`
    Builder.copyByteString body  -- (body is empty except for version -00)
  where
    header (k, v) = mconcat $ map Builder.copyByteString
        [CI.original k, ": ", v, "\r\n"]
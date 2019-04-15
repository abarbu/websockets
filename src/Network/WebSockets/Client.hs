{-# LANGUAGE FlexibleContexts #-}
--------------------------------------------------------------------------------
-- | This part of the library provides you with utilities to create WebSockets
-- clients (in addition to servers).
module Network.WebSockets.Client
    ( ClientApp
    , ClientApp'
    , runClient
    , runClientWith
    , runClientWithSocket
    , runClientWithStream
    , newClientConnection
    ) where


--------------------------------------------------------------------------------
import qualified Data.ByteString.Builder      as Builder
import           Control.Monad                 (void)
import           Data.IORef                    (newIORef)
import qualified Data.Text                     as T
import qualified Data.Text.Encoding            as T
import qualified Network.Socket                as S
import           Control.Monad.Base
import           Control.Monad.Trans.Control
import           Control.Exception.Lifted      (bracket, finally, throwIO)
import           Control.Monad.Fail

--------------------------------------------------------------------------------
import           Network.WebSockets.Connection
import           Network.WebSockets.Http
import           Network.WebSockets.Protocol
import           Network.WebSockets.Stream     (Stream)
import qualified Network.WebSockets.Stream     as Stream
import           Network.WebSockets.Types

--------------------------------------------------------------------------------
-- | A client application interacting with a single server. Once this
-- action finished, the underlying socket is closed automatically.
type ClientApp a = Connection -> IO a

-- | A generalized client application interacting with a single server. Once
-- this action finished, the underlying socket is closed automatically. The
-- first type parameter, 'm', must be restricted to be a 'MonadBase' 'IO' and
-- 'MonadBaseControl' 'IO' instance.
type ClientApp' m a = Connection -> m a


--------------------------------------------------------------------------------
-- TODO: Maybe this should all be strings
runClient :: (MonadBase IO m, MonadBaseControl IO m, MonadFail m) =>
            String       -- ^ Host
          -> Int          -- ^ Port
          -> String       -- ^ Path
          -> ClientApp' m a  -- ^ Client application
          -> m a
runClient host port path ws =
    runClientWith host port path defaultConnectionOptions [] ws


--------------------------------------------------------------------------------
runClientWith :: (MonadBase IO m, MonadBaseControl IO m, MonadFail m) =>
                String             -- ^ Host
              -> Int                -- ^ Port
              -> String             -- ^ Path
              -> ConnectionOptions  -- ^ Options
              -> Headers            -- ^ Custom headers to send
              -> ClientApp' m a        -- ^ Client application
              -> m a
runClientWith host port path0 opts customHeaders app = do
    -- Create and connect socket
    let hints = S.defaultHints
                    {S.addrSocketType = S.Stream}

        -- Correct host and path.
        fullHost = if port == 80 then host else (host ++ ":" ++ show port)
        path     = if null path0 then "/" else path0
    addr:_ <- liftBase $ S.getAddrInfo (Just hints) (Just host) (Just $ show port)
    sock      <- liftBase $ S.socket (S.addrFamily addr) S.Stream S.defaultProtocol
    liftBase $ S.setSocketOption sock S.NoDelay 1

    -- Connect WebSocket and run client
    res <- finally
        (liftBase (S.connect sock (S.addrAddress addr)) >>
         runClientWithSocket sock fullHost path opts customHeaders app)
        (liftBase $ S.close sock)

    -- Clean up
    return res


--------------------------------------------------------------------------------

runClientWithStream
    :: (MonadBase IO m, MonadBaseControl IO m, MonadFail m) =>
      Stream
    -- ^ Stream
    -> String
    -- ^ Host
    -> String
    -- ^ Path
    -> ConnectionOptions
    -- ^ Connection options
    -> Headers
    -- ^ Custom headers to send
    -> ClientApp' m a
    -- ^ Client application
    -> m a
runClientWithStream stream host path opts customHeaders app = do
    newClientConnection stream host path opts customHeaders >>= app

-- | Build a new 'Connection' from the client's point of view.
--
-- /WARNING/: Be sure to call 'Stream.close' on the given 'Stream' after you are
-- done using the 'Connection' in order to properly close the communication
-- channel. 'runClientWithStream' handles this for you, prefer to use it when
-- possible.
newClientConnection :: (MonadBase IO m, MonadBaseControl IO m, MonadFail m)
    => Stream
    -- ^ Stream that will be used by the new 'Connection'.
    -> String
    -- ^ Host
    -> String
    -- ^ Path
    -> ConnectionOptions
    -- ^ Connection options
    -> Headers
    -- ^ Custom headers to send
    -> m Connection
newClientConnection stream host path opts customHeaders = do
    -- Create the request and send it
    request    <- liftBase $ createRequest protocol bHost bPath False customHeaders
    liftBase $ Stream.write stream (Builder.toLazyByteString $ encodeRequestHead request)
    mbResponse <- liftBase $ Stream.parse stream decodeResponseHead
    response   <- case mbResponse of
        Just response -> return response
        Nothing       -> throwIO $ OtherHandshakeException $
            "Network.WebSockets.Client.newClientConnection: no handshake " ++
            "response from server"
    void $ either throwIO return $ finishResponse protocol request response
    parse   <- liftBase $ decodeMessages protocol
                (connectionFramePayloadSizeLimit opts)
                (connectionMessageDataSizeLimit opts) stream
    write   <- liftBase $ encodeMessages protocol ClientConnection stream
    sentRef <- liftBase $ newIORef False

    return $ Connection
        { connectionOptions   = opts
        , connectionType      = ClientConnection
        , connectionProtocol  = protocol
        , connectionParse     = parse
        , connectionWrite     = write
        , connectionSentClose = sentRef
        }
  where
    protocol = defaultProtocol  -- TODO
    bHost    = T.encodeUtf8 $ T.pack host
    bPath    = T.encodeUtf8 $ T.pack path


--------------------------------------------------------------------------------
runClientWithSocket :: (MonadBase IO m, MonadBaseControl IO m, MonadFail m) =>
                      S.Socket           -- ^ Socket
                    -> String             -- ^ Host
                    -> String             -- ^ Path
                    -> ConnectionOptions  -- ^ Options
                    -> Headers            -- ^ Custom headers to send
                    -> ClientApp' m a        -- ^ Client application
                    -> m a
runClientWithSocket sock host path opts customHeaders app = bracket
    (liftBase $ Stream.makeSocketStream sock)
    (liftBase . Stream.close)
    (\stream ->
        runClientWithStream stream host path opts customHeaders app)

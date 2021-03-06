{-# LANGUAGE DeriveDataTypeable #-}

-- | This module exports functions that allow you to safely use 'NS.Socket'
-- resources acquired and released outside a 'P.Proxy' pipeline.
--
-- Instead, if want to safely acquire and release resources within the
-- pipeline itself, then you should use the functions exported by
-- "Control.Proxy.TCP.Safe".
--
-- This module re-exports many functions from "Network.Simple.TCP"
-- module in the @network-simple@ package. You might refer to that
-- module for more documentation.


module Control.Proxy.TCP (
  -- * Client side
  -- $client-side
    S.connect

  -- * Server side
  -- $server-side
  , S.serve
  -- ** Listening
  , S.listen
  -- ** Accepting
  , S.accept
  , S.acceptFork

  -- * Socket streams
  -- $socket-streaming
  , socketReadS
  , nsocketReadS
  , socketWriteD
  -- ** Timeouts
  -- $socket-streaming-timeout
  , socketReadTimeoutS
  , nsocketReadTimeoutS
  , socketWriteTimeoutD

  -- * Note to Windows users
  -- $windows-users
  , NS.withSocketsDo

  -- * Types
  , S.HostPreference(..)
  , Timeout(..)
  ) where

import qualified Control.Exception              as E
import           Control.Monad.Trans.Class
import qualified Control.Proxy                  as P
import qualified Control.Proxy.Trans.Either     as PE
import qualified Data.ByteString                as B
import           Data.Data                      (Data,Typeable)
import           Data.Monoid
import qualified Network.Socket                 as NS
import qualified Network.Simple.TCP             as S
import           System.Timeout                 (timeout)


--------------------------------------------------------------------------------

-- $windows-users
--
-- If you are running Windows, then you /must/ call 'NS.withSocketsDo', just
-- once, right at the beginning of your program. That is, change your program's
-- 'main' function from:
--
-- @
-- main = do
--   print \"Hello world\"
--   -- rest of the program...
-- @
--
-- To:
--
-- @
-- main = 'NS.withSocketsDo' $ do
--   print \"Hello world\"
--   -- rest of the program...
-- @
--
-- If you don't do this, your networking code won't work and you will get many
-- unexpected errors at runtime. If you use an operating system other than
-- Windows then you don't need to do this, but it is harmless to do it, so it's
-- recommended that you do for portability reasons.

--------------------------------------------------------------------------------

-- $client-side
--
-- Here's how you could run a TCP client:
--
-- @
-- 'S.connect' \"www.example.org\" \"80\" $ \(connectionSocket, remoteAddr) -> do
--   putStrLn $ \"Connection established to \" ++ show remoteAddr
--   -- Now you may use connectionSocket as you please within this scope,
--   -- possibly using 'socketReadS', 'socketWriteD' or similar proxies
--   -- explained below.
-- @

--------------------------------------------------------------------------------

-- $server-side
--
-- Here's how you can run a TCP server that handles in different threads each
-- incoming connection to port @8000@ at IPv4 address @127.0.0.1@:
--
-- @
-- 'S.serve' ('S.Host' \"127.0.0.1\") \"8000\" $ \(connectionSocket, remoteAddr) -> do
--   putStrLn $ \"TCP connection established from \" ++ show remoteAddr
--   -- Now you may use connectionSocket as you please within this scope,
--   -- possibly using 'socketReadS', 'socketWriteD' or similar proxies
--   -- explained below.
-- @
--
-- If you need more control on the way your server runs, then you can use more
-- advanced functions such as 'listen', 'accept' and 'acceptFork'.

--------------------------------------------------------------------------------

-- $socket-streaming
--
-- Once you have a connected 'NS.Socket', you can use the following 'P.Proxy's
-- to interact with the other connection end using streams.

-- | Receives bytes from the remote end sends them downstream.
--
-- Less than the specified maximum number of bytes might be received at once.
--
-- This proxy returns if the remote peer closes its side of the connection or
-- EOF is received.
socketReadS
  :: P.Proxy p
  => Int                -- ^Maximum number of bytes to receive and send
                        -- dowstream at once. Any positive value is fine, the
                        -- optimal value depends on how you deal with the
                        -- received data. Try using @4096@ if you don't care.
  -> NS.Socket          -- ^Connected socket.
  -> () -> P.Producer p B.ByteString IO ()
socketReadS nbytes sock () = P.runIdentityP loop where
    loop = do
      mbs <- lift (S.recv sock nbytes)
      case mbs of
        Just bs -> P.respond bs >> loop
        Nothing -> return ()
{-# INLINABLE socketReadS #-}

-- | Just like 'socketReadS', except each request from downstream specifies the
-- maximum number of bytes to receive.
nsocketReadS
  :: P.Proxy p
  => NS.Socket          -- ^Connected socket.
  -> Int -> P.Server p Int B.ByteString IO ()
nsocketReadS sock = P.runIdentityK loop where
    loop nbytes = do
      mbs <- lift (S.recv sock nbytes)
      case mbs of
        Just bs -> P.respond bs >>= loop
        Nothing -> return ()
{-# INLINABLE nsocketReadS #-}

-- | Sends to the remote end the bytes received from upstream, then forwards
-- such same bytes downstream.
--
-- Requests from downstream are forwarded upstream.
socketWriteD
  :: P.Proxy p
  => NS.Socket          -- ^Connected socket.
  -> x -> p x B.ByteString x B.ByteString IO r
socketWriteD sock = P.runIdentityK loop where
    loop x = do
      a <- P.request x
      lift (S.send sock a)
      P.respond a >>= loop
{-# INLINABLE socketWriteD #-}

--------------------------------------------------------------------------------

-- $socket-streaming-timeout
--
-- These proxies behave like the similarly named ones above, except support for
-- timing out the interaction with the remote end is added.

-- | Like 'socketReadS', except it throws a 'Timeout' exception in the
-- 'PE.EitherP' proxy transformer if receiving data from the remote end takes
-- more time than specified.
socketReadTimeoutS
  :: P.Proxy p
  => Int                -- ^Timeout in microseconds (1/10^6 seconds).
  -> Int                -- ^Maximum number of bytes to receive and send
                        -- dowstream at once. Any positive value is fine, the
                        -- optimal value depends on how you deal with the
                        -- received data. Try using @4096@ if you don't care.
  -> NS.Socket          -- ^Connected socket.
  -> () -> P.Producer (PE.EitherP Timeout p) B.ByteString IO ()
socketReadTimeoutS wait nbytes sock () = loop where
    loop = do
      mmbs <- lift (timeout wait (S.recv sock nbytes))
      case mmbs of
        Just (Just bs) -> P.respond bs >> loop
        Just Nothing   -> return ()
        Nothing        -> PE.throw ex
    ex = Timeout $ "socketReadTimeoutS: " <> show wait <> " microseconds."
{-# INLINABLE socketReadTimeoutS #-}

-- | Like 'nsocketReadS', except it throws a 'Timeout' exception in the
-- 'PE.EitherP' proxy transformer if receiving data from the remote end takes
-- more time than specified.
nsocketReadTimeoutS
  :: P.Proxy p
  => Int                -- ^Timeout in microseconds (1/10^6 seconds).
  -> NS.Socket          -- ^Connected socket.
  -> Int -> P.Server (PE.EitherP Timeout p) Int B.ByteString IO ()
nsocketReadTimeoutS wait sock = loop where
    loop nbytes = do
      mmbs <- lift (timeout wait (S.recv sock nbytes))
      case mmbs of
        Just (Just bs) -> P.respond bs >>= loop
        Just Nothing   -> return ()
        Nothing        -> PE.throw ex
    ex = Timeout $ "nsocketReadTimeoutS: " <> show wait <> " microseconds."
{-# INLINABLE nsocketReadTimeoutS #-}

-- | Like 'socketWriteD', except it throws a 'Timeout' exception in the
-- 'PE.EitherP' proxy transformer if sending data to the remote end takes
-- more time than specified.
socketWriteTimeoutD
  :: P.Proxy p
  => Int                -- ^Timeout in microseconds (1/10^6 seconds).
  -> NS.Socket          -- ^Connected socket.
  -> x -> (PE.EitherP Timeout p) x B.ByteString x B.ByteString IO r
socketWriteTimeoutD wait sock = loop where
    loop x = do
      a <- P.request x
      m <- lift (timeout wait (S.send sock a))
      case m of
        Just () -> P.respond a >>= loop
        Nothing -> PE.throw ex
    ex = Timeout $ "socketWriteTimeoutD: " <> show wait <> " microseconds."
{-# INLINABLE socketWriteTimeoutD #-}

--------------------------------------------------------------------------------

-- |Exception thrown when a time limit has elapsed.
data Timeout
  = Timeout String -- ^Timeouted with an additional explanatory message.
  deriving (Eq, Show, Data, Typeable)

instance E.Exception Timeout where

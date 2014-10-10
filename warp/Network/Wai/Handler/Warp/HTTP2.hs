{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Network.Wai.Handler.Warp.HTTP2 where

import qualified Data.ByteString as BS
import qualified Network.HTTP.Types as H
import Network.Socket (SockAddr)
import Network.Wai
import Network.Wai.Handler.Warp.Types

import Network.HTTP2
import Network.HPACK
import Control.Monad (unless)

import Data.IntMap
import Control.Concurrent.STM.TQueue
import Data.IORef (IORef, readIORef)
import Data.Array.IO (IOUArray)
import Data.Array.IO (newListArray)

isHTTP2 :: Request -> Bool
isHTTP2 req = requestMethod req == "PRI" &&
              rawPathInfo req == "*"     &&
              httpVersion req == H.HttpVersion 2 0

-- fixme: Settings
http2 :: Connection -> InternalInfo -> SockAddr -> Bool -> Source -> Application -> IO ()
http2 Connection {..} _ii _addr _isSecure' src _app = do
    -- fixme
    ctx <- undefined
    frameDispatcher ctx src

type FrameQueue = TQueue Frame

data Context = Context {
    http2Settings :: IOUArray Int Int
  , idTable :: IORef (IntMap FrameQueue) -- fixme: heavy contention
  , outputQ :: FrameQueue
  , decodeHeaderTable :: IORef HeaderTable
  , encodeHeaderTable :: IORef HeaderTable
  }

-- fixme :: 1,6
newDefaultHttp2Settings :: IO (IOUArray Int Int)
newDefaultHttp2Settings = newListArray (1,6) [4096,1,-1,65535,16384,-1]

frameDispatcher :: Context -> Source -> IO ()
frameDispatcher ctx src = do
    bs <- readSource src
    unless (BS.null bs) $ do
        case decodeFrame defaultSettings bs of
            Left x            -> error (show x) -- fixme
            Right (frame,bs') -> do
                leftoverSource src bs'
                switch ctx $ framePayload frame
                frameDispatcher ctx src

---- looking up idTable
---- if exist, enqueue
---- otherwise creating queue, fork frameReader, and enqueue
switch :: Context -> FramePayload -> IO ()
switch Context{..} (HeadersFrame _ hdrblk) = do
    hdrtbl <- readIORef decodeHeaderTable
    (_hdrtbl', _hdr) <- decodeHeader hdrtbl hdrblk
    -- fixme: hdrtbl
    return ()
switch Context{..} (DataFrame _)          = undefined

-- updating settings
switch Context{..} (SettingsFrame _)      = undefined
-- resetting
switch Context{..} (RSTStreamFrame _)     = undefined
-- ponging
switch Context{..} (PingFrame _)          = undefined
-- cleanup
switch Context{..} (GoAwayFrame _ _ _)    = undefined

-- Not supported yet
switch Context{..} (PriorityFrame _)      = undefined
switch Context{..} (WindowUpdateFrame _)  = undefined
switch Context{..} (PushPromiseFrame _ _) = undefined
switch Context{..} (UnknownFrame _ _)    = undefined
switch Context{..} (ContinuationFrame _)  = undefined

-- frameReader
-- * Frames -> Request (with converting :authority)
-- * Launch App
-- * removing id from idTable
-- * Response -> Frames
-- * Timeout

-- frameSender
-- * Packing Frames to bytestream
-- * Sending bytestream

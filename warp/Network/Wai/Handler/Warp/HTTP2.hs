{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Network.Wai.Handler.Warp.HTTP2 where

import Blaze.ByteString.Builder
import Control.Arrow (first)
import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Monad (forever, unless, void)
import Data.Array.IO (IOUArray, newListArray)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import Data.CaseInsensitive (foldedCase, mk)
import Data.IORef (IORef, readIORef, newIORef, atomicModifyIORef', writeIORef)
import Data.IntMap (IntMap)
import qualified Data.IntMap as M
import Data.Monoid (mempty)
import qualified Network.HTTP.Types as H
import Network.Socket (SockAddr)
import Network.Wai
import Network.Wai.Handler.Warp.IO
import qualified Network.Wai.Handler.Warp.Settings as S (Settings, settingsNoParsePath)
import Network.Wai.Handler.Warp.Types
import Network.Wai.Internal (Request(..), Response(..), ResponseReceived(..))

import Network.HTTP2
import Network.HPACK

----------------------------------------------------------------

data Req = ReqH HeaderList
         | ReqC ByteString
         | ReqE ByteString

data Rsp = RspH Int H.Status H.ResponseHeaders
         | RspF Int (() -> IO ())
         | RspC Int ByteString
         | RspE Int ByteString

type ReqQueue = TQueue Req
type RspQueue = TQueue Rsp

data Context = Context {
    http2Settings :: IOUArray Int Int
  , idTable :: IORef (IntMap ReqQueue) -- fixme: heavy contention
  , outputQ :: RspQueue
  , encodeHeaderTable :: IORef HeaderTable
  , decodeHeaderTable :: IORef HeaderTable
  }

----------------------------------------------------------------

newContext :: IO Context
newContext = do
    st <- newDefaultHttp2Settings
    tbl <- newIORef (M.empty)
    q <- newTQueueIO
    eht <- newHeaderTableForEncoding 4096 >>= newIORef
    dht <- newHeaderTableForDecoding 4096 >>= newIORef
    return $ Context st tbl q eht dht

-- fixme :: 1,6
newDefaultHttp2Settings :: IO (IOUArray Int Int)
newDefaultHttp2Settings = newListArray (1,6) [4096,1,-1,65535,16384,-1]

----------------------------------------------------------------

http2ver :: H.HttpVersion
http2ver = H.HttpVersion 2 0

isHTTP2 :: Request -> Bool
isHTTP2 req = requestMethod req == "PRI" &&
              rawPathInfo req == "*"     &&
              httpVersion req == http2ver

----------------------------------------------------------------
-- fixme: Settings
http2 :: Connection -> InternalInfo -> SockAddr -> Bool -> Source -> Application -> IO ()
http2 conn _ii _addr _isSecure' src app = do
    ctx <- newContext
    void . forkIO $ frameReader ctx src app
    frameSender conn ctx

----------------------------------------------------------------

frameReader :: Context -> Source -> Application -> IO ()
frameReader ctx src app = do
    bs <- readSource src
    unless (BS.null bs) $ do
        case decodeFrame defaultSettings bs of
            Left x            -> error (show x) -- fixme
            Right (frame,bs') -> do
                leftoverSource src bs'
                switch ctx frame app
                frameReader ctx src app

switch :: Context -> Frame -> Application -> IO ()
switch Context{..} Frame{ framePayload = HeadersFrame _ hdrblk,
                          frameHeader = FrameHeader{..} } app = do
    hdrtbl <- readIORef decodeHeaderTable
    (hdrtbl', hdr) <- decodeHeader hdrtbl hdrblk
    writeIORef decodeHeaderTable hdrtbl'
    m0 <- readIORef idTable
    let stid = fromStreamIdentifier streamId
    -- fixme: need to testEndHeader
    case M.lookup stid m0 of
        Just _  -> error "bad header frame"
        Nothing -> do
            q <- newTQueueIO
            atomicModifyIORef' idTable$ \m -> (M.insert stid q m, ())
            atomically $ writeTQueue q (ReqH hdr)
            void . forkIO $ reqReader stid q outputQ app

switch Context{..} Frame{ framePayload = DataFrame body,
                          frameHeader = FrameHeader{..} } _ = do
    m <- readIORef idTable
    let stid = fromIntegral $ fromStreamIdentifier streamId
    case M.lookup stid m of
        Nothing -> error "No such stream"
        Just q  -> do
            let tag = if testEndStream flags then ReqE else ReqC
            atomically $ writeTQueue q (tag body)

switch Context{..} Frame{ framePayload = SettingsFrame _,
                          frameHeader = FrameHeader{..} } _ = return () -- fixme
{-
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
-}
switch _ _ _ = undefined

----------------------------------------------------------------

-- removing id from idTable?
-- timeout?
reqReader :: Int -> ReqQueue -> RspQueue -> Application -> IO ()
reqReader stid inpq outq app = do
    frag <- atomically $ readTQueue inpq
    case frag of
        ReqC _   -> error "ReqC"
        ReqE _   -> error "ReqE"
        ReqH hdr -> do
            let st = undefined
                query = undefined
                unparsedPath = undefined
                path = undefined
                settings = undefined
                addr = undefined
            let req = Request {
                    requestMethod = undefined -- fixme :method
                  , httpVersion = http2ver
                  , rawPathInfo = if S.settingsNoParsePath settings then unparsedPath else path
                  , pathInfo = H.decodePathSegments path
                  , rawQueryString = query
                  , queryString = H.parseQuery query
                  , requestHeaders = map (first mk) hdr -- fixme: removing ":foo"
                  , isSecure = False -- fixtme
                  , remoteHost = addr
                  , requestBody = undefined -- from fragments
                  , vault = mempty
                  , requestBodyLength = ChunkedBody -- fixme
                  , requestHeaderHost = undefined -- fixme :authority
                  , requestHeaderRange = undefined -- fixme:
                  }
            void $ app req enqueue
 where
   enqueue (ResponseBuilder st hdr bb) = do
       let h = RspH stid st hdr
       atomically $ writeTQueue outq h
       let d = RspE stid (toByteString bb) -- fixme
       atomically $ writeTQueue outq d
       return ResponseReceived

   enqueue _ = undefined -- fixme

{-
ResponseFile Status ResponseHeaders FilePath (Maybe FilePart)
ResponseBuilder Status ResponseHeaders Builder
ResponseStream Status ResponseHeaders StreamingBody
ResponseRaw (IO ByteString -> (ByteString -> IO ()) -> IO ()) Response
-}

----------------------------------------------------------------

-- * Packing Frames to bytestream
-- * Sending bytestream
frameSender :: Connection -> Context -> IO ()
frameSender Connection{..} Context{..} = forever $ do
    rsp <- atomically $ readTQueue outputQ
    case rsp of
        RspH stid st hdr -> do
            let status = B8.pack $ show $ H.statusCode st
                hdr' = (":status", status) : map (first foldedCase) hdr
            -- addServer
            -- addDate
            ehdrtbl <- readIORef encodeHeaderTable
            (ehdrtbl',hdrfrg) <- encodeHeader defaultEncodeStrategy ehdrtbl hdr'
            writeIORef encodeHeaderTable ehdrtbl'
            -- fixme endHeader
            let einfo = EncodeInfo (setEndHeader 0) (toStreamIdentifier stid) Nothing
                frame = HeadersFrame Nothing hdrfrg
                bytestream = encodeFrame einfo frame
            putStrLn "RspH"
            toBufIOWith connWriteBuffer connBufferSize connSendAll (fromByteString bytestream)
        RspE stid dat -> do
            let einfo = EncodeInfo (setEndStream 0) (toStreamIdentifier stid) Nothing
                frame = DataFrame dat
                bytestream = encodeFrame einfo frame
            putStrLn "RspE"
            toBufIOWith connWriteBuffer connBufferSize connSendAll (fromByteString bytestream)
        _ -> undefined

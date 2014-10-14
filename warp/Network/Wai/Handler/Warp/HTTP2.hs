{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Network.Wai.Handler.Warp.HTTP2 (isHTTP2, http2) where

import Blaze.ByteString.Builder
import Control.Arrow (first)
import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Monad (when, unless, void)
import Data.Array.IO (IOUArray, newListArray)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import Data.CaseInsensitive (foldedCase, mk)
import Data.IORef (IORef, readIORef, newIORef, writeIORef, modifyIORef)
import Data.IntMap (IntMap)
import qualified Data.IntMap as M
import Data.Maybe (fromJust)
import Data.Monoid (mempty)
import qualified Network.HTTP.Types as H
import Network.Socket (SockAddr)
import Network.Wai
import Network.Wai.Handler.Warp.Header
import Network.Wai.Handler.Warp.IO
import Network.Wai.Handler.Warp.Response
import qualified Network.Wai.Handler.Warp.Settings as S (Settings, settingsNoParsePath, settingsServerName)
import Network.Wai.Handler.Warp.Types
import Network.Wai.Internal (Request(..), Response(..), ResponseReceived(..))

import Network.HTTP2
import Network.HPACK

----------------------------------------------------------------

data Req = ReqHead HeaderList
         | ReqDatC ByteString
         | ReqDatE ByteString

data Rsp = RspHead Int H.Status H.ResponseHeaders
         | RspFunc Int (() -> IO ())
         | RspDatC Int ByteString
         | RspDatE Int ByteString
         | RspDone

type ReqQueue = TQueue Req
type RspQueue = TQueue Rsp

data Context = Context {
    http2Settings :: IOUArray Int Int
  -- fixme: clean up for frames whose end stream do not arrive
  , idTable :: IORef (IntMap ReqQueue)
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
http2 :: Connection -> InternalInfo -> SockAddr -> Bool -> S.Settings -> Source -> Application -> IO ()
http2 conn ii addr isSecure' settings src app = do
    ctx <- newContext
    void . forkIO $ frameReader ctx conn ii addr isSecure' settings src app
    frameSender conn ii settings ctx

----------------------------------------------------------------

data Next = None | Done | Fork Int ReqQueue

frameReader :: Context -> Connection -> InternalInfo -> SockAddr -> Bool -> S.Settings -> Source -> Application -> IO ()
frameReader ctx@Context{..} conn ii addr isSecure' settings src app = do
    bs <- readSource src
    unless (BS.null bs) $ do
        case decodeFrame defaultSettings bs of
            Left x            -> error (show x) -- fixme
            Right (frame,bs') -> do
                leftoverSource src bs'
                x <- switch ctx frame
                case x of
                    Done -> return ()
                    None -> frameReader ctx conn ii addr isSecure' settings src app
                    Fork stid  q -> do
                        void . forkIO $ reqReader stid q outputQ addr isSecure' settings app
                        frameReader ctx conn ii addr isSecure' settings src app

switch :: Context -> Frame -> IO Next
switch Context{..} Frame{ framePayload = HeadersFrame _ hdrblk,
                          frameHeader = FrameHeader{..} } = do
    hdrtbl <- readIORef decodeHeaderTable
    (hdrtbl', hdr) <- decodeHeader hdrtbl hdrblk
    writeIORef decodeHeaderTable hdrtbl'
    m0 <- readIORef idTable
    let stid = fromStreamIdentifier streamId
    case M.lookup stid m0 of
        Just _  -> error "bad header frame"
        Nothing -> do
            let end = testEndStream flags
            q <- newTQueueIO
            unless end $ modifyIORef idTable $ \m -> M.insert stid q m
            -- fixme: need to testEndHeader. ContinuationFrame is not
            -- support yet.
            atomically $ writeTQueue q (ReqHead hdr)
            return $ Fork stid q

switch Context{..} Frame{ framePayload = DataFrame body,
                          frameHeader = FrameHeader{..} } = do
    m0 <- readIORef idTable
    let stid = fromStreamIdentifier streamId
    case M.lookup stid m0 of
        Nothing -> error "No such stream"
        Just q  -> do
            let end = testEndStream flags
                tag = if end then ReqDatE else ReqDatC
            atomically $ writeTQueue q (tag body)
            when end $ modifyIORef idTable $ \m -> M.delete stid m
            return None

switch Context{..} Frame{ framePayload = SettingsFrame _,
                          frameHeader = FrameHeader{..} } = return None -- fixme

-- fixme :: clean up should be more complex than this
switch Context{..} Frame{ framePayload = GoAwayFrame _ _ _,
                          frameHeader = FrameHeader{..} } = do
    atomically $ writeTQueue outputQ RspDone
    return Done
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
switch Context{..} (UnknownFrame _ _)     = undefined
switch Context{..} (ContinuationFrame _)  = undefined
-}
switch _ Frame{..} = do
    putStrLn "switch"
    print $ toFrameTypeId $ framePayloadToFrameType framePayload
    return None

----------------------------------------------------------------

-- FIXME: removing id from idTable?
-- timeout?
reqReader :: Int -> ReqQueue -> RspQueue ->  SockAddr -> Bool -> S.Settings -> Application -> IO ()
reqReader stid inpq outq addr isSecure' settings app = do
    frag <- atomically $ readTQueue inpq
    case frag of
        ReqDatC _   -> error "ReqDatC"
        ReqDatE _   -> error "ReqDatE"
        ReqHead hdr -> do
            -- fixme: fromJust -> protocl error?
            let (unparsedPath,query) = B8.break (=='?') $ fromJust $ lookup ":path" hdr -- fixme
                path = H.extractPath unparsedPath
            let req = Request {
                    requestMethod = fromJust $ lookup ":method" hdr -- fixme
                  , httpVersion = http2ver
                  , rawPathInfo = if S.settingsNoParsePath settings then unparsedPath else path
                  , pathInfo = H.decodePathSegments path
                  , rawQueryString = query
                  , queryString = H.parseQuery query
                  , requestHeaders = map (first mk) hdr -- fixme: removing ":foo"
                  , isSecure = isSecure'
                  , remoteHost = addr
                  , requestBody = undefined -- from fragments
                  , vault = mempty
                  , requestBodyLength = ChunkedBody -- fixme
                  , requestHeaderHost = lookup ":authority" hdr
                  , requestHeaderRange = lookup "range" hdr
                  }
            void $ app req enqueue
 where
   enqueue (ResponseBuilder st hdr bb) = do
       let h = RspHead stid st hdr
       atomically $ writeTQueue outq h
       let d = RspDatE stid (toByteString bb) -- fixme
       atomically $ writeTQueue outq d
       return ResponseReceived

   enqueue _ = do -- fixme
       putStrLn "enqueue"
       return ResponseReceived

{-
ResponseFile Status ResponseHeaders FilePath (Maybe FilePart)
ResponseBuilder Status ResponseHeaders Builder
ResponseStream Status ResponseHeaders StreamingBody
ResponseRaw (IO ByteString -> (ByteString -> IO ()) -> IO ()) Response
-}

----------------------------------------------------------------

-- * Packing Frames to bytestream
-- * Sending bytestream
frameSender :: Connection -> InternalInfo -> S.Settings -> Context -> IO ()
frameSender Connection{..} ii settings Context{..} = loop
  where
    loop = do
        cont <- readQ >>= fill
        when cont loop
    readQ = atomically $ readTQueue outputQ
    fill (RspHead stid st hdr0) = do
        let dc = dateCacher ii
            rspidxhdr = indexResponseHeader hdr0
            defServer = S.settingsServerName settings
            addServerAndDate = addDate dc rspidxhdr . addServer defServer rspidxhdr
        hdr1 <- addServerAndDate hdr0
        let status = B8.pack $ show $ H.statusCode st
            hdr2 = (":status", status) : map (first foldedCase) hdr1
        ehdrtbl <- readIORef encodeHeaderTable
        (ehdrtbl',hdrfrg) <- encodeHeader defaultEncodeStrategy ehdrtbl hdr2
        writeIORef encodeHeaderTable ehdrtbl'
        -- fixme endHeader
        let einfo = EncodeInfo (setEndHeader defaultFlags) (toStreamIdentifier stid) Nothing
            frame = HeadersFrame Nothing hdrfrg
            bytestream = encodeFrame einfo frame
        putStrLn "RspHead"
        toBufIOWith connWriteBuffer connBufferSize connSendAll (fromByteString bytestream)
        return True

    fill (RspDatE stid dat) = do
        let einfo = EncodeInfo (setEndStream defaultFlags) (toStreamIdentifier stid) Nothing
            frame = DataFrame dat
            bytestream = encodeFrame einfo frame
        putStrLn "RspDatE"
        toBufIOWith connWriteBuffer connBufferSize connSendAll (fromByteString bytestream)
        return True

    fill RspDone = return False
    fill _ = do putStrLn "frameSender" >> return True

{-# LANGUAGE OverloadedStrings #-}

module Network.Wai.Handler.Warp.HTTP2 where

import qualified Network.HTTP.Types as H
import Network.Socket (SockAddr)
import Network.Wai
import Network.Wai.Handler.Warp.Settings
import Network.Wai.Handler.Warp.Types

isHTTP2 :: Request -> Bool
isHTTP2 req = requestMethod req == "PRI" &&
              rawPathInfo req == "*"     &&
              httpVersion req == H.HttpVersion 2 0

http2 :: Connection -> InternalInfo -> SockAddr -> Bool -> Settings -> Application -> IO ()
http2 _ _ _ _ _ _ = putStrLn "OOOOOKKKKK" -- fixme

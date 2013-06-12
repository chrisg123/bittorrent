-- |
--   Copyright   :  (c) Sam T. 2013
--   License     :  MIT
--   Maintainer  :  pxqr.sta@gmail.com
--   Stability   :  experimental
--   Portability :  portable
--
{-# LANGUAGE RecordWildCards #-}
module Network.BitTorrent
       (
         module Data.Torrent

         -- * Session
       , ClientSession
       , newClient

       , SwarmSession
       , newLeacher, newSeeder

         -- * Discovery
       , discover

         -- * Peer to Peer
       , P2P
       , Event(..)
       , PeerSession ( connectedPeerAddr, enabledExtensions )
       , Block(..), BlockIx(..), ppBlock, ppBlockIx

       , awaitEvent, yieldEvent
       ) where

import Control.Concurrent
import Control.Exception
import Control.Monad

import Data.IORef

import Network

import Data.Torrent
import Network.BitTorrent.Internal
import Network.BitTorrent.Exchange
import Network.BitTorrent.Exchange.Protocol
import Network.BitTorrent.Tracker



-- discover should hide tracker and DHT communication under the hood
-- thus we can obtain unified interface

discover :: SwarmSession -> P2P () -> IO ()
discover swarm action = do
  port <- listener swarm action

  let conn = TConnection (tAnnounce (torrentMeta swarm))
                         (tInfoHash (torrentMeta swarm))
                         (clientPeerID (clientSession swarm))
                          port

  progress <- getCurrentProgress (clientSession swarm)

  putStrLn "lookup peers"
  withTracker progress conn $ \tses -> do
    forever $ do
      addr <- getPeerAddr tses
      putStrLn "connecting to peer"
      handle handler (withPeer swarm addr action)

  where
    handler :: IOException -> IO ()
    handler _ = return ()

listener :: SwarmSession -> P2P () -> IO PortNumber
listener _ _ = do
  -- TODO:
--  forkIO loop
  return 10000

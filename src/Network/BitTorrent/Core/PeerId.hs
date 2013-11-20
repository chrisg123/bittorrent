-- |
--   Copyright   :  (c) Sam Truzjan 2013
--   License     :  BSD3
--   Maintainer  :  pxqr.sta@gmail.com
--   Stability   :  experimental
--   Portability :  portable
--
--  'PeerID' represent self assigned peer identificator. Ideally each
--  host in the network should have unique peer id to avoid
--  collisions, therefore for peer ID generation we use good entropy
--  source. (FIX not really) Peer ID is sent in /tracker request/,
--  sent and received in /peer handshakes/ and used in /distributed
--  hash table/ queries.
--
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Network.BitTorrent.Core.PeerId
       ( -- * PeerId
         PeerId (getPeerId)
       , ppPeerId

         -- * Generation
       , genPeerId
       , timestamp
       , entropy

         -- * Encoding
       , azureusStyle
       , shadowStyle

         -- * Decoding
       , clientInfo

         -- ** Extra
       , byteStringPadded
       , defaultClientId
       , defaultVersionNumber
       ) where

import Control.Applicative
import Data.Aeson
import Data.BEncode as BE
import Data.ByteString as BS
import Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Builder as BS
import Data.Default
import Data.Foldable    (foldMap)
import Data.List as L
import Data.Maybe       (fromMaybe)
import Data.Monoid
import Data.Serialize as S
import Data.Time.Clock  (getCurrentTime)
import Data.Time.Format (formatTime)
import Data.URLEncoded
import Data.Version     (Version(Version), versionBranch)
import System.Entropy   (getEntropy)
import System.Locale    (defaultTimeLocale)
import Text.PrettyPrint hiding ((<>))
import Text.Read        (readMaybe)
import Paths_bittorrent (version)

import Data.Torrent.Client


-- | Peer identifier is exactly 20 bytes long bytestring.
newtype PeerId = PeerId { getPeerId :: ByteString }
                 deriving (Show, Eq, Ord, BEncode, ToJSON, FromJSON)

instance Serialize PeerId where
  put = putByteString . getPeerId
  get = PeerId <$> getBytes 20

instance URLShow PeerId where
  urlShow = BC.unpack . getPeerId

-- | Format peer id in human readable form.
ppPeerId :: PeerId -> Doc
ppPeerId = text . BC.unpack . getPeerId

{-----------------------------------------------------------------------
--  Encoding
-----------------------------------------------------------------------}

-- | Pad bytestring so it's becomes exactly request length. Conversion
-- is done like so:
--
--     * length < size: Complete bytestring by given charaters.
--
--     * length = size: Output bytestring as is.
--
--     * length > size: Drop last (length - size) charaters from a
--     given bytestring.
--
byteStringPadded :: ByteString -- ^ bytestring to be padded.
                 -> Int        -- ^ size of result builder.
                 -> Char       -- ^ character used for padding.
                 -> BS.Builder
byteStringPadded bs s c =
      BS.byteString (BS.take s bs) <>
      BS.byteString (BC.replicate padLen c)
  where
    padLen = s - min (BS.length bs) s

-- | Azureus-style encoding have the following layout:
--
--     * 1  byte : '-'
--
--     * 2  bytes: client id
--
--     * 4  bytes: version number
--
--     * 1  byte : '-'
--
--     * 12 bytes: random number
--
azureusStyle :: ByteString -- ^ 2 character client ID, padded with 'H'.
             -> ByteString -- ^ Version number, padded with 'X'.
             -> ByteString -- ^ Random number, padded with '0'.
             -> PeerId     -- ^ Azureus-style encoded peer ID.
azureusStyle cid ver rnd = PeerId $ BL.toStrict $ BS.toLazyByteString $
    BS.char8 '-' <>
      byteStringPadded cid 2  'H' <>
      byteStringPadded ver 4  'X' <>
    BS.char8 '-' <>
      byteStringPadded rnd 12 '0'

-- | Shadow-style encoding have the following layout:
--
--     * 1 byte   : client id.
--
--     * 0-4 bytes: version number. If less than 4 then padded with
--     '-' char.
--
--     * 15 bytes : random number. If length is less than 15 then
--     padded with '0' char.
--
shadowStyle :: Char       -- ^ Client ID.
            -> ByteString -- ^ Version number.
            -> ByteString -- ^ Random number.
            -> PeerId     -- ^ Shadow style encoded peer ID.
shadowStyle cid ver rnd = PeerId $ BL.toStrict $ BS.toLazyByteString $
    BS.char8 cid <>
      byteStringPadded ver 4  '-' <>
      byteStringPadded rnd 15 '0'


-- | "HS" - 2 bytes long client identifier.
defaultClientId :: ByteString
defaultClientId = "HS"

-- | Gives exactly 4 bytes long version number for any version of the
-- package.  Version is taken from .cabal.
defaultVersionNumber :: ByteString
defaultVersionNumber = BS.take 4 $ BC.pack $ foldMap show $
                         versionBranch version

{-----------------------------------------------------------------------
--  Generation
-----------------------------------------------------------------------}

-- | Gives 15 characters long decimal timestamp such that:
--
--     * 6 bytes   : first 6 characters from picoseconds obtained with %q.
--
--     * 1 bytes   : character '.' for readability.
--
--     * 9..* bytes: number of whole seconds since the Unix epoch
--     (!)REVERSED.
--
--   Can be used both with shadow and azureus style encoding. This
--   format is used to make the ID's readable(for debugging) and more
--   or less random.
--
timestamp :: IO ByteString
timestamp = (BC.pack . format) <$> getCurrentTime
  where
    format t = L.take 6 (formatTime defaultTimeLocale "%q" t) ++ "." ++
               L.take 9 (L.reverse (formatTime defaultTimeLocale "%s" t))

-- | Gives 15 character long random bytestring. This is more robust
-- method for generation of random part of peer ID than timestamp.
entropy :: IO ByteString
entropy = getEntropy 15

-- NOTE: entropy generates incorrrect peer id

-- |  Here we use Azureus-style encoding with the following args:
--
--      * 'HS' for the client id.
--
--      * Version of the package for the version number
--
--      * UTC time day ++ day time for the random number.
--
genPeerId :: IO PeerId
genPeerId = azureusStyle defaultClientId defaultVersionNumber <$> timestamp

{-----------------------------------------------------------------------
--  Decoding
-----------------------------------------------------------------------}

parseImpl :: ByteString -> ClientImpl
parseImpl = f . BC.unpack
 where
  f "AG" = IAres
  f "A~" = IAres
  f "AR" = IArctic
  f "AV" = IAvicora
  f "AX" = IBitPump
  f "AZ" = IAzureus
  f "BB" = IBitBuddy
  f "BC" = IBitComet
  f "BF" = IBitflu
  f "BG" = IBTG
  f "BR" = IBitRocket
  f "BS" = IBTSlave
  f "BX" = IBittorrentX
  f "CD" = IEnhancedCTorrent
  f "CT" = ICTorrent
  f "DE" = IDelugeTorrent
  f "DP" = IPropagateDataClient
  f "EB" = IEBit
  f "ES" = IElectricSheep
  f "FT" = IFoxTorrent
  f "GS" = IGSTorrent
  f "HL" = IHalite
  f "HS" = IlibHSbittorrent
  f "HN" = IHydranode
  f "KG" = IKGet
  f "KT" = IKTorrent
  f "LH" = ILH_ABC
  f "LP" = ILphant
  f "LT" = ILibtorrent
  f "lt" = ILibTorrent
  f "LW" = ILimeWire
  f "MO" = IMonoTorrent
  f "MP" = IMooPolice
  f "MR" = IMiro
  f "MT" = IMoonlightTorrent
  f "NX" = INetTransport
  f "PD" = IPando
  f "qB" = IqBittorrent
  f "QD" = IQQDownload
  f "QT" = IQt4TorrentExample
  f "RT" = IRetriever
  f "S~" = IShareaza
  f "SB" = ISwiftbit
  f "SS" = ISwarmScope
  f "ST" = ISymTorrent
  f "st" = Isharktorrent
  f "SZ" = IShareaza
  f "TN" = ITorrentDotNET
  f "TR" = ITransmission
  f "TS" = ITorrentstorm
  f "TT" = ITuoTu
  f "UL" = IuLeecher
  f "UT" = IuTorrent
  f "VG" = IVagaa
  f "WT" = IBitLet
  f "WY" = IFireTorrent
  f "XL" = IXunlei
  f "XT" = IXanTorrent
  f "XX" = IXtorrent
  f "ZT" = IZipTorrent
  f _    = IUnknown

-- | Tries to extract meaningful information from peer ID bytes. If
-- peer id uses unknown coding style then client info returned is
-- 'def'.
--
clientInfo :: PeerId -> ClientInfo
clientInfo pid = either (const def) id $ runGet getCI (getPeerId pid)
  where -- TODO other styles
    getCI = getWord8 >> ClientInfo <$> getClientImpl <*> getClientVersion
    getClientImpl    = parseImpl   <$> getByteString 2
    getClientVersion = mkVer       <$> getByteString 4
      where
        mkVer bs = ClientVersion $ Version [fromMaybe 0 $ readMaybe $ BC.unpack bs] []
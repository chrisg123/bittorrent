-- |
--   Copyright   :  (c) Sam T. 2013
--   License     :  MIT
--   Maintainer  :  pxqr.sta@gmail.com
--   Stability   :  experimental
--   Portability :  portable
--
--   Normally peer to peer communication consisting of the following
--   steps:
--
--   * In order to establish the connection between peers we should
--   send 'Handshake' message. The 'Handshake' is a required message
--   and must be the first message transmitted by the peer to the
--   another peer. Another peer should reply with a handshake as well.
--
--   * Next peer might sent bitfield message, but might not. In the
--   former case we should update bitfield peer have. Again, if we
--   have some pieces we should send bitfield. Normally bitfield
--   message should sent after the handshake message.
--
--   * Regular exchange messages. TODO docs
--
--   For more high level API see "Network.BitTorrent.Exchange" module.
--
--   For more infomation see:
--   <https://wiki.theory.org/BitTorrentSpecification#Peer_wire_protocol_.28TCP.29>
--
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
module Network.BitTorrent.Exchange.Protocol
       ( -- * Inital handshake
         Handshake(..), ppHandshake
       , handshake , handshakeCaps

         -- ** Defaults
       , defaultHandshake, defaultBTProtocol, defaultReserved
       , handshakeMaxSize

         -- * Block
       , PieceIx, BlockLIx, PieceLIx
       , BlockIx(..), ppBlockIx
       , Block(..),  ppBlock ,blockSize
       , pieceIx, blockIx
       , blockRange, ixRange, isPiece

         -- ** Defaults
       , defaultBlockSize

         -- * Regular messages
       , Message(..)
       , ppMessage

         -- * control
       , PeerStatus(..)
       , choking, interested

       , SessionStatus(..)
       , clientStatus, peerStatus
       , canUpload, canDownload

         -- ** Defaults
       , defaultUnchokeSlots
       ) where

import Control.Applicative
import Control.Exception
import Control.Monad
import Control.Lens
import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as Lazy
import Data.Default
import Data.Serialize as S
import Data.Int
import Data.Word
import Text.PrettyPrint

import Network
import Network.Socket.ByteString

import Data.Bitfield
import Data.Torrent
import Network.BitTorrent.Extension
import Network.BitTorrent.Peer



{-----------------------------------------------------------------------
    Handshake
-----------------------------------------------------------------------}

-- | Handshake message is used to exchange all information necessary
-- to establish connection between peers.
--
data Handshake = Handshake {
    -- | Identifier of the protocol.
    hsProtocol    :: ByteString

    -- | Reserved bytes used to specify supported BEP's.
  , hsReserved    :: Capabilities

    -- | Info hash of the info part of the metainfo file. that is
    -- transmitted in tracker requests. Info hash of the initiator
    -- handshake and response handshake should match, otherwise
    -- initiator should break the connection.
    --
  , hsInfoHash    :: InfoHash

    -- | Peer id of the initiator. This is usually the same peer id
    -- that is transmitted in tracker requests.
    --
  , hsPeerID      :: PeerID

  } deriving (Show, Eq)

instance Serialize Handshake where
  put hs = do
    putWord8 (fromIntegral (B.length (hsProtocol hs)))
    putByteString (hsProtocol hs)
    putWord64be   (hsReserved hs)
    put (hsInfoHash hs)
    put (hsPeerID hs)

  get = do
    len  <- getWord8
    Handshake <$> getBytes (fromIntegral len)
              <*> getWord64be
              <*> get
              <*> get

-- | Extract capabilities from a peer handshake message.
handshakeCaps :: Handshake -> Capabilities
handshakeCaps = hsReserved

-- | Format handshake in human readable form.
ppHandshake :: Handshake -> Doc
ppHandshake Handshake {..} =
  text (BC.unpack hsProtocol) <+> ppClientInfo (clientInfo hsPeerID)

-- | Get handshake message size in bytes from the length of protocol
-- string.
handshakeSize :: Word8 -> Int
handshakeSize n = 1 + fromIntegral n + 8 + 20 + 20

-- | Maximum size of handshake message in bytes.
handshakeMaxSize :: Int
handshakeMaxSize = handshakeSize 255

-- | Default protocol string "BitTorrent protocol" as is.
defaultBTProtocol :: ByteString
defaultBTProtocol = "BitTorrent protocol"

-- | Default reserved word is 0.
defaultReserved :: Word64
defaultReserved = 0

-- | Length of info hash and peer id is unchecked, so it /should/ be
-- equal 20.
defaultHandshake :: InfoHash -> PeerID -> Handshake
defaultHandshake = Handshake defaultBTProtocol defaultReserved

-- | Handshaking with a peer specified by the second argument.
handshake :: Socket -> Handshake -> IO Handshake
handshake sock hs = do
    putStrLn "send handshake"
    sendAll sock (S.encode hs)

    putStrLn "recv handshake size"
    header <- recv sock 1
    when (B.length header == 0) $
      throw $ userError "Unable to receive handshake."

    let protocolLen = B.head header
    let restLen     = handshakeSize protocolLen - 1

    putStrLn "recv handshake body"
    body <- recv sock restLen
    let resp = B.cons protocolLen body

    case checkIH (S.decode resp) of
      Right hs' -> return hs'
      Left msg  -> throwIO $ userError $ msg ++ " in handshake body."
  where
    checkIH (Right hs')
      | hsInfoHash hs /= hsInfoHash hs'
      = Left "Handshake info hash do not match."
    checkIH x = x

{-----------------------------------------------------------------------
    Blocks
-----------------------------------------------------------------------}

type BlockLIx = Int
type PieceLIx = Int


data BlockIx = BlockIx {
    -- | Zero-based piece index.
    ixPiece  :: {-# UNPACK #-} !PieceLIx

    -- | Zero-based byte offset within the piece.
  , ixOffset :: {-# UNPACK #-} !Int

    -- | Block size starting from offset.
  , ixLength :: {-# UNPACK #-} !Int
  } deriving (Show, Eq)

getInt :: Get Int
getInt = fromIntegral <$> getWord32be
{-# INLINE getInt #-}

putInt :: Putter Int
putInt = putWord32be . fromIntegral
{-# INLINE putInt #-}

instance Serialize BlockIx where
  {-# SPECIALIZE instance Serialize BlockIx #-}
  get = BlockIx <$> getInt <*> getInt <*> getInt
  {-# INLINE get #-}

  put i = do putInt (ixPiece i)
             putInt (ixOffset i)
             putInt (ixLength i)
  {-# INLINE put #-}

-- | Format block index in human readable form.
ppBlockIx :: BlockIx -> Doc
ppBlockIx BlockIx {..} =
  "piece  = " <> int ixPiece  <> "," <+>
  "offset = " <> int ixOffset <> "," <+>
  "length = " <> int ixLength

data Block = Block {
    -- | Zero-based piece index.
    blkPiece  :: {-# UNPACK #-} !PieceLIx

    -- | Zero-based byte offset within the piece.
  , blkOffset :: {-# UNPACK #-} !Int

    -- | Payload.
  , blkData   :: !ByteString
  } deriving (Show, Eq)

-- | Format block in human readable form. Payload is ommitted.
ppBlock :: Block -> Doc
ppBlock = ppBlockIx . blockIx

blockSize :: Block -> Int
blockSize blk = B.length (blkData blk)

-- | Widely used semi-official block size.
defaultBlockSize :: Int
defaultBlockSize = 16 * 1024


isPiece :: Int -> Block -> Bool
isPiece pieceSize (Block i offset bs) =
  offset == 0 && B.length bs == pieceSize && i >= 0
{-# INLINE isPiece #-}

pieceIx :: Int -> Int -> BlockIx
pieceIx i = BlockIx i 0
{-# INLINE pieceIx #-}

blockIx :: Block -> BlockIx
blockIx = BlockIx <$> blkPiece <*> blkOffset <*> B.length . blkData

blockRange :: (Num a, Integral a) => Int -> Block -> (a, a)
blockRange pieceSize blk = (offset, offset + len)
  where
    offset = fromIntegral pieceSize * fromIntegral (blkPiece blk)
           + fromIntegral (blkOffset blk)
    len    = fromIntegral (B.length (blkData blk))
{-# INLINE blockRange #-}
{-# SPECIALIZE blockRange :: Int -> Block -> (Int64, Int64) #-}

ixRange :: (Num a, Integral a) => Int -> BlockIx -> (a, a)
ixRange pieceSize i = (offset, offset + len)
  where
    offset = fromIntegral  pieceSize * fromIntegral (ixPiece i)
           + fromIntegral (ixOffset i)
    len    = fromIntegral (ixLength i)
{-# INLINE ixRange #-}
{-# SPECIALIZE ixRange :: Int -> BlockIx -> (Int64, Int64) #-}


{-----------------------------------------------------------------------
    Regular messages
-----------------------------------------------------------------------}

-- | Messages used in communication between peers.
--
--   Note: If some extensions are disabled (not present in extension
--   mask) and client receive message used by the disabled
--   extension then the client MUST close the connection.
--
data Message = KeepAlive
             | Choke
             | Unchoke
             | Interested
             | NotInterested

               -- | Zero-based index of a piece that has just been
               -- successfully downloaded and verified via the hash.
             | Have     !PieceIx

               -- | The bitfield message may only be sent immediately
               -- after the handshaking sequence is complete, and
               -- before any other message are sent. If client have no
               -- pieces then bitfield need not to be sent.
             | Bitfield !Bitfield

               -- | Request for a particular block. If a client is
               -- requested a block that another peer do not have the
               -- peer might not answer at all.
             | Request  !BlockIx

               -- | Response for a request for a block.
             | Piece    !Block

               -- | Used to cancel block requests. It is typically
               -- used during "End Game".
             | Cancel   !BlockIx

             | Port     !PortNumber

               -- | BEP 6: Then peer have all pieces it might send the
               --   'HaveAll' message instead of 'Bitfield'
               --   message. Used to save bandwidth.
             | HaveAll

               -- | BEP 6: Then peer have no pieces it might send
               -- 'HaveNone' message intead of 'Bitfield'
               -- message. Used to save bandwidth.
             | HaveNone

               -- | BEP 6: This is an advisory message meaning "you
               -- might like to download this piece." Used to avoid
               -- excessive disk seeks and amount of IO.
             | SuggestPiece !PieceIx

               -- | BEP 6: Notifies a requesting peer that its request
               -- will not be satisfied.
             | RejectRequest !BlockIx

               -- | BEP 6: This is an advisory messsage meaning "if
               -- you ask for this piece, I'll give it to you even if
               -- you're choked." Used to shorten starting phase.
             | AllowedFast !PieceIx
               deriving (Show, Eq)


instance Serialize Message where
  get = do
    len <- getInt
--    _   <- lookAhead $ ensure len
    if len == 0 then return KeepAlive
      else do
        mid <- getWord8
        case mid of
          0x00 -> return Choke
          0x01 -> return Unchoke
          0x02 -> return Interested
          0x03 -> return NotInterested
          0x04 -> Have     <$> getInt
          0x05 -> (Bitfield . fromBitmap) <$> getByteString (pred len)
          0x06 -> Request  <$> get
          0x07 -> Piece    <$> getBlock (len - 9)
          0x08 -> Cancel   <$> get
          0x09 -> (Port . fromIntegral) <$> getWord16be
          0x0E -> return HaveAll
          0x0F -> return HaveNone
          0x0D -> SuggestPiece  <$> getInt
          0x10 -> RejectRequest <$> get
          0x11 -> AllowedFast   <$> getInt
          _    -> do
            rm <- remaining >>= getBytes
            fail $ "unknown message ID: " ++ show mid ++ "\n"
                ++ "remaining available bytes: " ++ show rm

    where
      getBlock :: Int -> Get Block
      getBlock len = Block <$> getInt <*> getInt <*> getBytes len
      {-# INLINE getBlock #-}


  put KeepAlive     = putInt 0
  put Choke         = putInt 1  >> putWord8 0x00
  put Unchoke       = putInt 1  >> putWord8 0x01
  put Interested    = putInt 1  >> putWord8 0x02
  put NotInterested = putInt 1  >> putWord8 0x03
  put (Have i)      = putInt 5  >> putWord8 0x04 >> putInt i
  put (Bitfield bf) = putInt l  >> putWord8 0x05 >> putLazyByteString b
    where b = toBitmap bf
          l = succ (fromIntegral (Lazy.length b))
          {-# INLINE l #-}
  put (Request blk) = putInt 13 >> putWord8 0x06 >> put blk
  put (Piece   blk) = putInt l  >> putWord8 0x07 >> putBlock
    where l = 9 + B.length (blkData blk)
          {-# INLINE l #-}
          putBlock = do putInt (blkPiece blk)
                        putInt (blkOffset  blk)
                        putByteString (blkData blk)
          {-# INLINE putBlock #-}

  put (Cancel  blk)      = putInt 13 >> putWord8 0x08 >> put blk
  put (Port    p  )      = putInt 3  >> putWord8 0x09 >> putWord16be (fromIntegral p)
  put  HaveAll           = putInt 1  >> putWord8 0x0E
  put  HaveNone          = putInt 1  >> putWord8 0x0F
  put (SuggestPiece pix) = putInt 5  >> putWord8 0x0D >> putInt pix
  put (RejectRequest i ) = putInt 13 >> putWord8 0x10 >> put i
  put (AllowedFast   i ) = putInt 5  >> putWord8 0x11 >> putInt i


-- | Format messages in human readable form. Note that output is
--   compact and suitable for logging: only useful information but not
--   payload bytes.
--
ppMessage :: Message -> Doc
ppMessage (Bitfield _)       = "Bitfield"
ppMessage (Piece blk)        = "Piece"    <+> ppBlock blk
ppMessage (Cancel i )        = "Cancel"   <+> ppBlockIx i
ppMessage (SuggestPiece pix) = "Suggest"  <+> int pix
ppMessage (RejectRequest i ) = "Reject"   <+> ppBlockIx i
ppMessage msg = text (show msg)

{-----------------------------------------------------------------------
    Peer Status
-----------------------------------------------------------------------}

-- |
data PeerStatus = PeerStatus {
    _choking    :: Bool
  , _interested :: Bool
  }

$(makeLenses ''PeerStatus)

instance Default PeerStatus where
  def = PeerStatus True False

-- |
data SessionStatus = SessionStatus {
    _clientStatus :: PeerStatus
  , _peerStatus   :: PeerStatus
  }

$(makeLenses ''SessionStatus)

instance Default SessionStatus where
  def = SessionStatus def def

-- | Can the /client/ transfer to the /peer/?
canUpload :: SessionStatus -> Bool
canUpload SessionStatus {..}
  = _interested _peerStatus && not (_choking _clientStatus)

-- | Can the /client/ transfer from the /peer/?
canDownload :: SessionStatus -> Bool
canDownload SessionStatus {..}
  = _interested _clientStatus && not (_choking _peerStatus)

-- | Indicates how many peers are allowed to download from the client
-- by default.
defaultUnchokeSlots :: Int
defaultUnchokeSlots = 4
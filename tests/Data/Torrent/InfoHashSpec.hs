{-# OPTIONS -fno-warn-orphans #-}
module Data.Torrent.InfoHashSpec (spec) where

import Control.Applicative
import System.FilePath
import Test.Hspec
import Test.QuickCheck
import Test.QuickCheck.Instances ()

import Data.Torrent
import Data.Torrent.InfoHash as IH


instance Arbitrary InfoHash where
  arbitrary = IH.hash <$> arbitrary

type TestPair = (FilePath, String)

-- TODO add a few more torrents here
torrentList :: [TestPair]
torrentList =
  [ ( "res" </> "dapper-dvd-amd64.iso.torrent"
    , "0221caf96aa3cb94f0f58d458e78b0fc344ad8bf")
  ]

infohashSpec :: (FilePath, String) -> Spec
infohashSpec (filepath, expectedHash) = do
  it ("should match " ++ filepath) $ do
    torrent    <- fromFile filepath
    let actualHash = show $ idInfoHash $ tInfoDict torrent
    actualHash `shouldBe` expectedHash

spec :: Spec
spec = do
  describe "info hash" $ do
    mapM_ infohashSpec torrentList

-- SPDX-FileCopyrightText: 2023 Arnout Engelen <arnout@bzzt.net>
-- SPDX-FileCopyrightText: 2023 Dylan Green <dylan.green@obsidian.systems>
--
-- SPDX-License-Identifier: MIT

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE CPP #-}
module LocalSecurityScanner.NVD where

import LocalSecurityScanner.Utils
import LocalSecurityScanner.Types
import qualified LocalSecurityScanner.CVE as CVE

import Control.Monad
import qualified Data.Text as T
import Data.Text(Text)
import qualified Data.Text.Encoding as TE
import Data.Time.Clock
import Data.Time.Format.ISO8601
import Data.Aeson
import Data.Aeson.TH
import Data.Functor
import Data.Maybe
import GHC.Generics (Generic)
import Network.Http.Client
import OpenSSL
import System.Directory
import System.IO.Streams (InputStream)
import Data.ByteString (ByteString)
import Data.Map (fromList)
import System.Environment.Blank
import Control.Concurrent
import Data.Map(Map, toList)
import Control.Exception
import Control.Monad.Log
import Prettyprinter
import Control.Monad.IO.Class
import Control.Monad.Trans.Reader

data NVDResponse = NVDResponse
  { _nvdresponse_resultsPerPage :: Int
  , _nvdresponse_startIndex :: Int
  , _nvdresponse_totalResults :: Int
  , _nvdresponse_format :: Text
  , _nvdresponse_version :: Text
  , _nvdresponse_timestamp :: Text
  , _nvdresponse_vulnerabilities :: [NVDWrapper]
  } deriving (Show, Eq, Ord, Generic)

newtype CVSS2Metric = Cvss2Metric { _cvss2metric_baseSeverity :: Text }
    deriving (Show, Eq, Ord, Generic)
newtype CVSS3xData = Cvss3xData { _cvss3xdata_baseSeverity :: Text }
    deriving (Show, Eq, Ord, Generic)
newtype CVSS3xMetric = Cvss3xMetric { _cvss3xmetric_cvssData :: CVSS3xData }
    deriving (Show, Eq, Ord, Generic)

-- TODO support for non-cvss-v31 severities
data Metric = Metric
  { _metric_cvssMetricV2 :: Maybe [CVSS2Metric]
  , _metric_cvssMetricV30 :: Maybe [CVSS3xMetric]
  , _metric_cvssMetricV31 :: Maybe [CVSS3xMetric]
  } deriving (Show, Eq, Ord, Generic)

newtype NVDWrapper = NVDWrapper { _nvdwrapper_cve :: NVDCVE }
    deriving (Show, Eq, Ord)

data NVDCVE = NVDCVE
  { _nvdcve_id :: Text --
  , _nvdcve_sourceIdentifier :: Maybe Text
  , _nvdcve_vulnStatus :: Maybe Text
  , _nvdcve_published :: Text --
  , _nvdcve_lastModified :: Text --
  , _nvdcve_evaluatorComment :: Maybe Text
  , _nvdcve_evaluatorSolution :: Maybe Text
  , _nvdcve_evaluatorImpact :: Maybe Text
  , _nvdcve_cisaExploitAdd :: Maybe Text
  , _nvdcve_cisaActionDue :: Maybe Text
  , _nvdcve_cisaRequiredAction :: Maybe Text
  , _nvdcve_cisaVulnerabilityName :: Maybe Text
  , _nvdcve_descriptions :: [LangString] --
  , _nvdcve_references :: [Reference] --
  , _nvdcve_metrics :: Maybe Metric
  , _nvdcve_weaknesses :: Maybe [Weakness]
  , _nvdcve_configurations :: Maybe [Configuration]
  , _nvdcve_vendorComments :: Maybe [VendorComment]
  } deriving (Show, Eq, Ord, Generic)

data LangString = LangString
  { _langstring_lang :: Text
  , _langstring_value :: Text
  } deriving (Show, Eq, Ord, Generic)

data Reference = Reference
  { _reference_url :: Text
  , _reference_source :: Maybe Text
  , _reference_tags :: Maybe [Text]
  } deriving (Show, Eq, Ord, Generic)

data VendorComment = VendorComment
  { _vendorcomment_organization :: Text
  , _vendorcomment_comment :: Text
  , _vendorcomment_lastModified :: Text
  } deriving (Show, Eq, Ord, Generic)

data Weakness = Weakness
  { _weakness_source :: Text
  , _weakness_type :: Text
  , _weakness_description :: [LangString]
  } deriving (Show, Eq, Ord, Generic)

data Configuration = Configuration
  { _configuration_operator :: Maybe Text
  , _configuration_negate :: Maybe Bool
  , _configuration_nodes :: [Node]
  } deriving (Show, Eq, Ord)

data Node = Node
  { _node_operator :: Text
  , _node_negate :: Maybe Bool
  , _node_cpeMatch :: [CPEMatch]
  } deriving (Show, Eq, Ord, Generic)

data CPEMatch = CPEMatch
  { _cpematch_vulnerable :: Bool
  , _cpematch_criteria :: Text
  , _cpematch_matchCriteriaId :: Text
  , _cpematch_versionStartExcluding :: Maybe Text
  , _cpematch_versionStartIncluding :: Maybe Text
  , _cpematch_versionEndExcluding :: Maybe Text
  , _cpematch_versionEndIncluding :: Maybe Text
  } deriving (Show, Eq, Ord, Generic)

data LocalCache = LocalCache
  { _localcache_cveId :: Text
  , _localcache_pname :: Text
  , _localcache_version :: Text
  } deriving (Show, Eq, Ord, Generic)

data CacheStatus = CacheStatus
  { _cachestatus_last_updated :: UTCTime
  , _cachestatus_format_version :: Int
  }

get' :: URL -> (Response -> InputStream ByteString -> IO a) -> IO a
get' a b = withOpenSSL $ do
    putStrLn "[NVD] NVD_API_KEY environment variable not found."
    putStrLn "[NVD] Request an API key from https://nvd.nist.gov/developers/start-here to reduce rate limits."
    putStrLn "[NVD] waiting 8 seconds.."
    let second = 1000000
    threadDelay $ second * 8
    get a b

mconcat <$> sequence (deriveJSON stripType' <$>
    [ ''NVDResponse
    , ''NVDCVE
    , ''NVDWrapper
    , ''LangString
    , ''Reference
    , ''VendorComment
    , ''Weakness
    , ''Configuration
    , ''Node
    , ''CPEMatch
    , ''LocalCache
    , ''CacheStatus
    , ''Metric
    , ''CVSS2Metric
    , ''CVSS3xMetric
    , ''CVSS3xData
    ])

keywordSearch :: LogT m ann => Text -> ReaderT Parameters m NVDResponse
keywordSearch t = nvdApi $ fromList [("keywordSearch", t)]

cveSearch :: LogT m ann => Text -> ReaderT Parameters m NVDResponse
cveSearch t = nvdApi $ fromList [("cveId", t)]

cacheDirectory :: LogT m ann => ReaderT Parameters m String
cacheDirectory = do
    cacheDirCli <- cacheDir <$> ask
    case cacheDirCli of
      Just dir -> pure $ dir <> "/"
      Nothing -> do
        xdg_cache <- liftIO $ getEnv "XDG_CACHE_HOME"
        cachedir <- case xdg_cache of
          Just dir -> pure $ dir <> "/NixLocalSecurityScanner/NVD/"
          Nothing -> do
            home <- liftIO $ getEnv "HOME"
            pure $ case home of
              Just h -> h <> "/.cache/NixLocalSecurityScanner/NVD/"
              Nothing -> "./NixLocalSecurityScanner-cache/NVD/"
        liftIO $ createDirectoryIfMissing True cachedir
        pure cachedir

writeToDisk :: LogT m ann => NVDResponse -> ReaderT Parameters m ()
writeToDisk resp = do
    let t = map (_nvdwrapper_cve) $ _nvdresponse_vulnerabilities resp
    flip mapM_ t $ \x -> do
        let id' = _nvdcve_id x
        cachedir <- cacheDirectory
        liftIO $ encodeFile (cachedir <> T.unpack id' <> ".json") x

showDuration :: NominalDiffTime -> String
showDuration = showDur . floor
  where
    showDur :: Integer -> String
    showDur s =
      if s < 60
      then (show s) <> "s"
      else (show $ div s 60) <> "m" <> (showDur $ mod s 60)

getPages :: LogT m ann => [(Text, Text)] -> ReaderT Parameters m [NVDResponse]
getPages params = do
  debug' <- debug <$> ask
  when debug' $ logDebug $ "Getting first response from NVD"
  start <- liftIO getCurrentTime
  response1 <- nvdApi $ fromList params
  let st = _nvdresponse_totalResults response1
      results = _nvdresponse_resultsPerPage response1
      (numOfPages, _) = properFraction $ ((fromIntegral st / fromIntegral results) :: Double)
  go [] start numOfPages (numOfPages, results)
  where
    go :: LogT m ann => [NVDResponse] -> UTCTime -> Int -> (Int, Int) -> ReaderT Parameters m [NVDResponse]
    go acc start total (pagesToGo, results) = do
        logInfo $ pretty $ "[NVD] Got partial data, " <> (show pagesToGo) <> "/" <> (show total) <> " pages to go"
        current <- liftIO getCurrentTime
        let pagesRemaining = total - pagesToGo + 1
        let remaining = (diffUTCTime current start) * (fromIntegral pagesToGo) / (fromIntegral pagesRemaining)
        -- TODO show in minutes
        logInfo $ pretty $ "[NVD] " <> (showDuration $ diffUTCTime current start) <> " elapsed, " <> (showDuration remaining) <> " remaining"
        let st = pagesToGo * results
        resp <- nvdApi (fromList $ ("startIndex", (tshow st)) : params)
        if pagesToGo <= 0 then
            pure (acc <> [resp])
        else go (acc <> [resp]) start total (pagesToGo - 1, results)

getEverything :: LogT m ann => ReaderT Parameters m [NVDResponse]
getEverything = getPages []

getEverythingSince :: LogT m ann => UTCTime -> UTCTime -> ReaderT Parameters m [NVDResponse]
getEverythingSince since to = do
  -- TODO handle the case that the cache is more than 120 days old
  getPages [
    ("lastModStartDate", T.pack $ iso8601Show since),
    ("lastModEndDate", T.pack $ iso8601Show to) ]

data NVDException = CacheMalformed !FilePath
  deriving (Show)
instance Exception NVDException

loadCacheStatus :: LogT m ann => ReaderT Parameters m (Maybe CacheStatus)
loadCacheStatus = do
  cachedir <- cacheDirectory
  let filename = cachedir <> "/status.json"
  exists <- liftIO $ doesFileExist $ filename
  if exists then liftIO $ (decodeFileStrict filename :: IO (Maybe CacheStatus))
  else pure Nothing

writeCacheStatus :: LogT m ann => UTCTime -> ReaderT Parameters m ()
writeCacheStatus startTime = do
  cachedir <- cacheDirectory
  let filename = cachedir <> "/status.json"
  liftIO $ encodeFile filename $ CacheStatus startTime 1

updateNVDCVECache :: LogT m ann => UTCTime -> ReaderT Parameters m ()
updateNVDCVECache since = do
  debug' <- debug <$> ask
  startTime <- liftIO $ getCurrentTime

  updated <- getEverythingSince since startTime
  when debug' $ logDebug $ "Got updates, writing to cache"
  mapM_ writeToDisk updated
  writeCacheStatus startTime

loadNVDCVEsFromCache :: LogT m ann => ReaderT Parameters m [NVDCVE]
loadNVDCVEsFromCache = do
  cachedir <- cacheDirectory
  files' <- liftIO $ listDirectory cachedir
  let files = filter (\x -> not (x == "status.json")) files'
  flip mapM files $ \filename -> do
    parsed <- liftIO $ do
      (decodeFileStrict' $ cachedir <> filename :: IO (Maybe NVDCVE))
    case parsed of
      Just cve -> pure cve
      Nothing -> throw $ CacheMalformed filename

loadNVDCVEs :: LogT m ann => ReaderT Parameters m [NVDCVE]
loadNVDCVEs = do
  -- https://nvd.nist.gov/developers/terms-of-use
  logInfo "This product uses the NVD API but is not endorsed or certified by the NVD."
  cacheStatus <- loadCacheStatus
  debug' <- debug <$> ask
  case cacheStatus of
    Just status -> do
      let lastUpdated = _cachestatus_last_updated status
      currentTime <- liftIO getCurrentTime
      logInfo "Loading NVD data from cache"
      logInfo $ pretty $ "Cache last updated: " <> (show $ lastUpdated)
      let cacheAge = diffUTCTime currentTime lastUpdated
      let threeDays = 3 * 24 * 60 * 60
      when (cacheAge > threeDays) $ updateNVDCVECache lastUpdated
      loadNVDCVEsFromCache
    Nothing -> do
      logInfo "CVE data from NVD not yet cached, fetching. This will take considerable time for the first import."
      startTime <- liftIO $ getCurrentTime

      everything <- getEverything
      when debug' $ logDebug "Got everything, writing to cache"
      mapM_ writeToDisk everything
      writeCacheStatus startTime
      pure $ map _nvdwrapper_cve $ concatMap _nvdresponse_vulnerabilities everything



nvdApi :: LogT m ann => Map Text Text -> ReaderT Parameters m NVDResponse
nvdApi r = go 0
  where
      go :: LogT m ann => Int -> ReaderT Parameters m NVDResponse
      go count = do
        let baseUrl = "https://services.nvd.nist.gov/rest/json/cves/2.0?"
            url = baseUrl <> (convertToApi $ toList r)
        debug' <- debug <$> ask
        v <- liftIO $ (try (withApiKey (get' url jsonHandler) $ \key ->
            getWithHeaders' (fromList [("apiKey", key)]) url jsonHandler)) :: LogT m ann => m (Either SomeException NVDResponse)
        when debug' $ logDebug $ pretty $ show url
        case v of
          Left e -> do
              when debug' $ logDebug $ pretty $ show e
              logWarning $ "Failed to parse, waiting for 10 seconds and retrying.."
              logWarning $ pretty $ "Retry count: " <> show count
              liftIO $ threadDelay $ 1000000 * 10
              go (count + 1)
          Right c -> pure c



withApiKey
    :: IO a
    -> (ByteString -> IO a)
    -> IO a
withApiKey f1 f = do
    apiKey <- getEnv "NVD_API_KEY"
    case apiKey of
      Nothing -> f1
      Just apiKey' -> f (TE.encodeUtf8 $ T.pack $ apiKey')

getSeverity :: NVDCVE -> Maybe Text
getSeverity cve =
    let
        (severities2 :: [Text]) = concat $ maybeToList $ (_nvdcve_metrics cve) >>= _metric_cvssMetricV2 <&> (map _cvss2metric_baseSeverity)
        (severities30 :: [Text]) = concat $ maybeToList $ (_nvdcve_metrics cve) >>= _metric_cvssMetricV30 <&> (map $ _cvss3xdata_baseSeverity . _cvss3xmetric_cvssData)
        (severities31 :: [Text]) = concat $ maybeToList $ (_nvdcve_metrics cve) >>= _metric_cvssMetricV31 <&> (map $ _cvss3xdata_baseSeverity . _cvss3xmetric_cvssData)
    in
        listToMaybe $ severities31 ++ severities30 ++ severities2

-- convert NVDCVE JSON data type to our internal feed-agnostic LocalVuln data model:
convertToLocal :: LogT m ann => [NVDCVE] -> ReaderT Parameters m [[LocalVuln]]
convertToLocal nvds = do
    excludeVendors' <- excludeVendors <$> ask
    timeLog $ Named (__FILE__ <> ":" <> (tshow (__LINE__ :: Integer))) $ flip mapM nvds $ \x -> do
      let configs = _nvdcve_configurations x
          severity = getSeverity x
          -- TODO support for multiple or non-cvss-v31 severities
          id' = _nvdcve_id x
          versions = case configs of
            Nothing -> []
            Just cfg -> flip concatMap cfg $ \cc -> do
                let cpeMatch = (concatMap _node_cpeMatch (_configuration_nodes cc))
                flip concatMap cpeMatch $ \c -> do
                    let versionStartIncluding = _cpematch_versionStartIncluding c
                        versionStartExcluding = _cpematch_versionStartExcluding c
                        versionEndIncluding = _cpematch_versionEndIncluding c
                        versionEndExcluding = _cpematch_versionEndExcluding c
                        cpe = (CVE.parseCPE $ _cpematch_criteria c)
                    case excludeVendors' of
                      Nothing -> [LocalVuln versionStartIncluding versionStartExcluding versionEndIncluding versionEndExcluding (CVE._cpe_product <$> cpe) id' severity]
                      Just v -> if (CVE._cpe_vendor <$> cpe) `elem` (map (Just . T.pack) v) then
                        []
                      else [LocalVuln versionStartIncluding versionStartExcluding versionEndIncluding versionEndExcluding (CVE._cpe_product <$> cpe) id' severity]
      pure versions

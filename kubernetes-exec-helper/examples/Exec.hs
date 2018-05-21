{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}


module Main where

import           GHC.Conc(labelThread)
import           Control.Monad(forever, replicateM, replicateM_, forM)
import           Control.Concurrent.Async
import           Control.Concurrent.STM
import           Control.Concurrent(threadDelay)
import           Control.Exception.Safe
import           System.IO
import qualified Kubernetes.K8SChannel as K8SChannel
import           Data.Foldable as Foldable
import           Data.Function
import           Data.Maybe
import           Data.Proxy
import           Data.Text
import           Data.Text.IO as T
import           Text.Printf as Printf
import           Data.Yaml (decodeFile, decodeEither, decodeFileEither, ParseException)
import           Data.Maybe (fromJust)
import           Kubernetes.Client (dispatchMime, MimeResult(..)) 
import           Kubernetes.ClientHelper
import           Network.WebSockets as WS
import           Network.Socket
import           Kubernetes.WSClient as WSClient
import           Kubernetes.KubeConfig
import           Kubernetes.Model
import           Kubernetes.Core(KubernetesRequest(..), KubernetesConfig(..), newConfig)
import           Kubernetes.MimeTypes
import           Kubernetes.CreateWSClient as CreateWSClient
import           Kubernetes.API.CoreV1
import           Options.Applicative
                      (execParser 
                        , Parser, info, fullDesc, help
                        , metavar, long, metavar
                        , strOption)
import           Data.Semigroup ((<>))
import           Network.TLS as TLS          (credentialLoadX509, ClientParams(..))
import           System.Environment
output :: K8SChannel.ChannelId -> TChan Text -> IO ()
output aChannelId aChannel = do 
  let handle = K8SChannel.mapChannel aChannelId
  hSetBuffering handle NoBuffering
  forever $ do 
    text <- readLine $ aChannel
    T.hPutStr handle text


setupKubeConfig :: IO KubernetesConfig
setupKubeConfig = do
    newConfig
    & fmap (setMasterURI "https://192.168.99.100:8443")    -- fill in master URI
    & fmap disableValidateAuthMethods  -- if using client cert auth

clusterClientSetupParams :: IO TLS.ClientParams
clusterClientSetupParams = do
    home <- getEnv("HOME")
    caStoreFile <- return $ Printf.printf "%s/.minikube/ca.crt" (pack home)
    clientCrt <- return $ Printf.printf "%s/.minikube/client.crt" home
    clientKey <- return $ Printf.printf "%s/.minikube/client.key" home 
    myCAStore <- loadPEMCerts caStoreFile -- if using custom CA certs
    myCert    <- credentialLoadX509 clientCrt clientKey 
                  >>= either error return

    defaultTLSClientParams
      & fmap disableServerNameValidation -- if master address is specified as an IP address
      & fmap disableServerCertValidation -- if you don't want to validate the server cert at all (insecure)          
      & fmap (setCAStore myCAStore)      -- if using custom CA certs
      & fmap (setClientCert myCert)      -- if using client cert


listPods :: KubernetesConfig -> IO (Kubernetes.Client.MimeResult V1PodList)
listPods kubeConfig = do 
    tlsParams <- clusterClientSetupParams
    manager <- newManager tlsParams
    dispatchMime
            manager
            kubeConfig
            (Kubernetes.API.CoreV1.listPodForAllNamespaces (Accept MimeJSON))


getBearerToken :: FilePath -> IO AuthApiKeyBearerToken 
getBearerToken aFile = 
    T.readFile aFile >>= \x -> return $ AuthApiKeyBearerToken x

setupAndRun :: Text -> IO ()
setupAndRun containerName = do
  kubeConfig <- setupKubeConfig
  tlsParams <- clusterClientSetupParams
  podsForNamespaces <- listPods kubeConfig
  (MimeResult containerResult response) <- getContainer podsForNamespaces containerName
  case containerResult of 
    Right container__ -> iterContainers tlsParams kubeConfig container__
    Left _ -> return ()
  return ()
  where 
    iterContainers :: ClientParams -> KubernetesConfig -> V1Container -> IO ()
    iterContainers tlsParams kubeConfig containerE = do
          print ("..." :: String)
          apiBearerToken <- getBearerToken "./bearerToken.txt" -- TODO fix this.
          clientState <- createWSClient tlsParams kubeConfig containerE $ 
              ([
                Command $ "/bin/sh -c echo This message goes to stderr >&2; echo This message goes to stdout"])
          client <- 
            async $ 
              WSClient.runClient clientState (Name containerName) (Namespace "default")
                apiBearerToken
          
          outputAsyncs <- mapM (\(channelId, channel) -> async(output channelId channel)) 
            $ Prelude.filter(\(cId, _) -> cId /= K8SChannel.StdIn) $ 
              CreateWSClient.channels clientState
          _ <- waitAny $ client : outputAsyncs
          return ()

-- | A sample test setup, that should be moved to 
-- | test spec. 
main :: IO ()
main = setupAndRun "busybox-test"

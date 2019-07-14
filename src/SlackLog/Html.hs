{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE StrictData        #-}

module SlackLog.Html
  ( convertToHtmlFile
  , renderSlackMessages
  , renderIndexOfPages
  , loadWorkspaceInfo
  , parsePageNumber
  , PageInfo(..)
  , WorkspaceInfo(..)
  ) where


import           Control.Applicative     ((<|>))
import qualified Data.Aeson              as Json
import qualified Data.ByteString.Lazy    as BL
import           Data.Char               (isDigit)
import qualified Data.HashMap.Strict     as HM
import           Data.List               (sortOn)
import           Data.Maybe              (fromMaybe)
import qualified Data.Text               as T
import qualified Data.Time.Clock         as TC
import qualified Data.Time.Format        as TF
import qualified Data.Time.LocalTime     as LT
import qualified Data.Time.Zones         as TZ
import           Html                    (( # ))
import qualified Html                    as H
import qualified Html.Attribute          as A
import           Safe                    (lastMay)
import           System.FilePath         (takeBaseName, (<.>), (</>))
import qualified Web.Slack.Common        as Slack
import qualified Web.Slack.MessageParser as Slack

import           SlackLog.Types          (ChannelId, ChannelName,
                                          Config (timeZone, workspaceName),
                                          UserId, UserName)
import           SlackLog.Util           (failWhenLeft, readJsonFile)


data PageInfo = PageInfo
  { currentPagePath  :: FilePath
  , previousPagePath :: Maybe FilePath
  , nextPagePath     :: Maybe FilePath
  , channelId        :: ChannelId
  } deriving (Eq, Show)

data WorkspaceInfo = WorkspaceInfo
  { userNameById      :: HM.HashMap UserId UserName
  , channelNameById   :: HM.HashMap ChannelId ChannelName
  , groupNameById     :: HM.HashMap ChannelId ChannelName
  , workspaceInfoName :: T.Text
  , getTimeDiff       :: TC.UTCTime -> LT.TimeZone
  }


-- | Assumes this function is executed in doc/ directory
convertToHtmlFile :: Show a => (FilePath -> a) -> WorkspaceInfo -> PageInfo -> IO ()
convertToHtmlFile key ws pg =
  BL.writeFile htmlPath =<< renderSlackMessages key ws pg jsonPath
 where
  cid = channelId pg
  currentPath = currentPagePath pg
  jsonPath = ensurePathIn "json" cid currentPath
  htmlPath = ensurePathIn "html" cid currentPath


renderSlackMessages
  :: Show a => (FilePath -> a) -> WorkspaceInfo -> PageInfo -> FilePath -> IO BL.ByteString
renderSlackMessages key wsi@WorkspaceInfo {..} PageInfo {..} = fmap render . readJsonFile
 where
  render msgs = H.renderByteString
    ( H.doctype_
    # H.html_
      ( H.head_
        ( H.meta_A (A.charset_ ("utf-8" :: T.Text))
        # H.title_ title
        # H.link_A
          ( A.rel_ ("stylesheet" :: T.Text)
          # A.href_ ("/messages.css" :: T.Text)
          # A.type_ ("text/css" :: T.Text)
          # A.media_ ("screen" :: T.Text)
          )
        )
      # H.body_
        ( H.h1_ title
        # pager
        # H.div_A (A.class_ ("message_list" :: T.Text)) (map messageDiv msgs)
        # pager
        )
      )
    )

  title =
    workspaceInfoName <> " / " <> getChannelScreenName wsi channelId <> " #" <> T.pack (show $ key currentPagePath)

  pager = H.div_A (A.class_ ("pager" :: T.Text))
    ( ((\pp -> H.a_A (A.href_ pp # prevClass) prevLabel) . ("/" ++) . ensurePathIn "html" channelId <$> previousPagePath)
    # ((\pp -> H.a_A (A.href_ pp # nextClass) nextLabel) . ("/" ++) . ensurePathIn "html" channelId <$> nextPagePath)
    )
   where
    prevClass = A.class_ ("pager__previous" :: T.Text)
    nextClass = A.class_ ("pager__next" :: T.Text)

    prevLabel, nextLabel :: T.Text
    prevLabel = "Previous"
    nextLabel = "Next"

  messageDiv Slack.Message { messageTs, messageUser, messageText } =
    H.div_A (A.class_ ("message" :: T.Text) # A.id_ ("message-" <> Slack.slackTimestampTs messageTs))
      ( H.div_A (A.class_ ("message__timestamp" :: T.Text))
        (H.Raw . timestampBlock $ Slack.slackTimestampTime messageTs)
      # H.div_A (A.class_ ("message__header" :: T.Text))
        userName
      # H.div_A (A.class_ ("message__body" :: T.Text))
        (H.Raw $ mkMessageBody wsi messageText)
      )
   where
    userName = getUserScreenName wsi messageUser
    timestampBlock tm =
      let lt = LT.utcToZonedTime (getTimeDiff tm) tm
      in TF.formatTime TF.defaultTimeLocale "%Y-%m-%d<br/>%T %z" lt


-- | Assumes this function is executed in doc/ directory
loadWorkspaceInfo :: FilePath -> IO WorkspaceInfo
loadWorkspaceInfo dir = do
  userNameById <- failWhenLeft =<< Json.eitherDecodeFileStrict' (dir </> ".users.json")
  channelNameById <- failWhenLeft =<< Json.eitherDecodeFileStrict' (dir </> ".channels.json")
  groupNameById <- failWhenLeft =<< Json.eitherDecodeFileStrict' (dir </> ".groups.json")

  cfg <- failWhenLeft =<< Json.eitherDecodeFileStrict' (dir </> ".config.json")
  let workspaceInfoName = workspaceName cfg
  getTimeDiff <- fmap TZ.timeZoneForUTCTime . TZ.loadTZFromDB $ timeZone cfg

  return WorkspaceInfo {..}


renderIndexOfPages
  :: (Ord a, Show a)
  => (FilePath -> a) -> WorkspaceInfo -> [(ChannelId, [FilePath])] -> IO BL.ByteString
renderIndexOfPages key wsi@WorkspaceInfo {..} =
  fmap wrapBody
    . traverse (\(cid, jsonPaths) -> do
      let sortedJsonPaths = sortOn key jsonPaths
      case lastMay sortedJsonPaths of
          Just lastPath -> do
            lastLastMessage <- readLastMessage lastPath
            Just . channelSummary cid lastPath lastLastMessage
              <$> mapM (\path -> channelDetail cid path <$> readFirstMessage path) sortedJsonPaths
          _ ->
            return Nothing
      )
 where
  wrapBody body =
    H.renderByteString
      ( H.doctype_
      # H.html_
        ( H.head_
          ( H.meta_A (A.charset_ ("utf-8" :: T.Text))
          # H.title_ title
          # H.link_A
            ( A.rel_ ("stylesheet" :: T.Text)
            # A.href_ ("/index.css" :: T.Text)
            # A.type_ ("text/css" :: T.Text)
            # A.media_ ("screen" :: T.Text)
            )
          )
        # H.body_
          ( H.h1_ title
          # H.div_A (A.class_ ("channels_list" :: T.Text)) body
          )
        )
      )
  title = "Slack log of " <> workspaceInfoName

  channelSummary cid lastJsonPath Slack.Message { messageTs } details =
    H.details_A (A.class_ ("channel" :: T.Text))
    ( H.summary_A (A.class_ ("channel__name" :: T.Text))
      ( H.a_A (A.href_ ("/" ++ ensurePathIn "html" cid lastJsonPath)) (getChannelScreenName wsi cid)
      # (" (Last updated at " <> timestampWords (Slack.slackTimestampTime messageTs) <> ")")
      )
      # details
    )

  channelDetail cid jsonPath Slack.Message { messageTs, messageUser, messageText } =
    H.ul_A (A.class_ ("pages_list" :: T.Text))
    ( H.li_A (A.class_ ("page" :: T.Text))
      ( H.a_A (A.href_ ("/" ++ ensurePathIn "html" cid jsonPath))
        ("#" <> T.pack (show (key jsonPath)))
      # (" " :: T.Text)
      # H.span_A (A.class_ ("page__first_message" :: T.Text))
        ( (H.span_A (A.class_ ("page__first_message__header" :: T.Text)) (getUserScreenName wsi messageUser))
        # (": " :: T.Text)
        #  H.span_A (A.class_ ("page__first_message__body" :: T.Text))
            (H.Raw $ mkMessageBody wsi messageText)
        # (" at " :: T.Text)
        # ( H.span_A (A.class_ ("page__first_message__timestamp" :: T.Text))
            . timestampWords $ Slack.slackTimestampTime messageTs
          )
        )
      )
    )

  readFirstMessage :: FilePath -> IO Slack.Message
  readFirstMessage = fmap head . readJsonFile

  readLastMessage :: FilePath -> IO Slack.Message
  readLastMessage = fmap last . readJsonFile

  timestampWords tm =
    let lt = LT.utcToZonedTime (getTimeDiff tm) tm
    in TF.formatTime TF.defaultTimeLocale "%Y-%m-%d %T %z" lt


mkMessageBody :: WorkspaceInfo -> Slack.SlackMessageText -> T.Text
mkMessageBody wsi mText =
  Slack.messageToHtml Slack.defaultHtmlRenderers (getUserName wsi) mText


ensurePathIn :: String -> ChannelId -> FilePath -> FilePath
ensurePathIn typ cid name = typ ++ "/" ++ T.unpack cid ++ "/" ++ takeBaseName name <.> typ


getChannelScreenName :: WorkspaceInfo -> ChannelId -> ChannelName
getChannelScreenName WorkspaceInfo {..} cid  =
  fromMaybe cid (HM.lookup cid channelNameById <|> HM.lookup cid groupNameById)


getUserName :: WorkspaceInfo -> Slack.UserId -> UserName
getUserName WorkspaceInfo {..} suid =
  let uid = Slack.unUserId suid in fromMaybe uid (HM.lookup uid userNameById)


getUserScreenName :: WorkspaceInfo -> Maybe Slack.UserId -> UserName
getUserScreenName wsi = maybe "<non-user>" $ getUserName wsi


parsePageNumber :: FilePath -> Integer
parsePageNumber = read . takeWhile isDigit . takeBaseName
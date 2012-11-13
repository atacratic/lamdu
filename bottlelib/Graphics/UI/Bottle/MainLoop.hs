module Graphics.UI.Bottle.MainLoop (mainLoopAnim, mainLoopImage, mainLoopWidget) where

import Control.Arrow(first, second)
import Control.Concurrent(threadDelay)
import Control.Lens ((^.))
import Control.Monad (liftM, when)
import Data.IORef
import Data.MRUMemo (memoIO)
import Data.StateVar (($=))
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import Data.Vector.Vector2 (Vector2(..))
import Graphics.DrawingCombinators ((%%))
import Graphics.DrawingCombinators.Utils (Image)
import Graphics.UI.Bottle.Animation(AnimId)
import Graphics.UI.Bottle.Widget(Widget)
import Graphics.UI.GLFW.Events (KeyEvent, GLFWEvent(..), eventLoop)
import qualified Graphics.DrawingCombinators as Draw
import qualified Graphics.Rendering.OpenGL.GL as GL
import qualified Graphics.UI.Bottle.Animation as Anim
import qualified Graphics.UI.Bottle.EventMap as E
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.GLFW as GLFW
import qualified Graphics.UI.GLFW.Utils as GLFWUtils

mainLoopImage
  :: (Widget.Size -> KeyEvent -> IO Bool)
  -> (Bool -> Widget.Size -> IO (Maybe Image)) -> IO a
mainLoopImage eventHandler makeImage = GLFWUtils.withGLFW $ do
  Vector2 displayWidth displayHeight <- GLFWUtils.getVideoModeSize
  GLFWUtils.openWindow GLFW.defaultDisplayOptions
    { GLFW.displayOptions_width = displayWidth
    , GLFW.displayOptions_height = displayHeight
    }
  let
    windowSize = do
      (x, y) <- GLFW.getWindowDimensions
      return $ Vector2 (fromIntegral x) (fromIntegral y)

    handleEvent size (GLFWKeyEvent keyEvent) =
      eventHandler size keyEvent
    handleEvent _ GLFWWindowClose =
      error "Quit" -- TODO: Make close event
    handleEvent _ GLFWWindowRefresh = return True

    handleEvents events = do
      winSize@(Vector2 winSizeX winSizeY) <- windowSize
      anyChange <- fmap or $ mapM (handleEvent winSize) events
      GL.viewport $=
        (GL.Position 0 0,
         GL.Size (round winSizeX) (round winSizeY))
      mNewImage <- makeImage anyChange winSize
      case mNewImage of
        Nothing ->
          -- TODO: If we can verify that there's sync-to-vblank, we
          -- need no sleep here
          threadDelay 10000
        Just image ->
          Draw.clearRender .
          (Draw.translate (-1, 1) %%) .
          (Draw.scale (2/winSizeX) (-2/winSizeY) %%) $
          image
  eventLoop handleEvents

mainLoopAnim
  :: (Widget.Size -> IO (Maybe (AnimId -> AnimId)))
  -> (Widget.Size -> KeyEvent -> IO (Maybe (AnimId -> AnimId)))
  -> (Widget.Size -> IO Anim.Frame)
  -> IO Anim.R -> IO a
mainLoopAnim tickHandler eventHandler makeFrame getAnimationHalfLife = do
  frameStateVar <- newIORef Nothing
  let
    handleResult Nothing = return False
    handleResult (Just animIdMapping) = do
      (modifyIORef frameStateVar . fmap)
        ((first . const) 0 .
         (second . second . Anim.mapIdentities) animIdMapping)
      return True

    nextFrameState curTime size Nothing = do
      dest <- makeFrame size
      return $ Just (0, (curTime, dest))
    nextFrameState curTime size (Just (drawCount, (prevTime, prevFrame))) =
      if drawCount == 0
      then do
        dest <- makeFrame size
        animationHalfLife <- getAnimationHalfLife
        let
          elapsed = realToFrac (curTime `diffUTCTime` prevTime)
          progress = 1 - 0.5 ** (elapsed/animationHalfLife)
        return . Just $
          case Anim.nextFrame progress dest prevFrame of
            Nothing -> (drawCount + 1, (curTime, dest))
            Just newFrame -> (0 :: Int, (curTime, newFrame))
      else
        return $ Just (drawCount + 1, (curTime, prevFrame))

    makeImage forceRedraw size = do
      when forceRedraw .
        modifyIORef frameStateVar .
        fmap . first $ const 0
      _ <- handleResult =<< tickHandler size
      curTime <- getCurrentTime
      writeIORef frameStateVar =<<
        nextFrameState curTime size =<< readIORef frameStateVar
      liftM frameStateResult $ readIORef frameStateVar

    frameStateResult Nothing = error "No frame to draw at start??"
    frameStateResult (Just (drawCount, (_, frame)))
      | drawCount < stopAtDrawCount = Just $ Anim.draw frame
      | otherwise = Nothing
    -- A note on draw counts:
    -- When a frame is dis-similar to the previous the count resets to 0
    -- When a frame is similar and animation stops the count becomes 1
    -- We then should draw it again (for double buffering issues) at count 2
    -- And stop drawing it at count 3.
    stopAtDrawCount = 3
    imgEventHandler size event =
      handleResult =<< eventHandler size event
  mainLoopImage imgEventHandler makeImage

compose :: [a -> a] -> a -> a
compose = foldr (.) id

mainLoopWidget :: (Widget.Size -> IO (Widget IO)) -> IO Anim.R -> IO a
mainLoopWidget mkWidgetUnmemod getAnimationHalfLife = do
  mkWidgetRef <- newIORef =<< memoIO mkWidgetUnmemod
  let
    newWidget = writeIORef mkWidgetRef =<< memoIO mkWidgetUnmemod
    getWidget size = ($ size) =<< readIORef mkWidgetRef
    tickHandler size = do
      widget <- getWidget size
      tickResults <-
        sequence $ Widget.wEventMap widget ^. E.emTickHandlers
      case tickResults of
        [] -> return Nothing
        _ -> do
          newWidget
          return . Just . compose . map Widget.eAnimIdMapping $ tickResults
    eventHandler size event = do
      widget <- getWidget size
      mAnimIdMapping <-
        maybe (return Nothing) (liftM (Just . Widget.eAnimIdMapping)) .
        E.lookup event $ Widget.wEventMap widget
      case mAnimIdMapping of
        Nothing -> return ()
        Just _ -> newWidget
      return mAnimIdMapping
    mkFrame size = liftM Widget.wFrame $ getWidget size
  mainLoopAnim tickHandler eventHandler mkFrame getAnimationHalfLife

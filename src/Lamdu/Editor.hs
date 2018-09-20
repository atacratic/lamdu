-- | The GUI editor
{-# LANGUAGE RankNTypes, DisambiguateRecordFields #-}
module Lamdu.Editor
    ( run
    ) where

import           Control.Concurrent.MVar
import           Control.DeepSeq (deepseq)
import qualified Control.Exception as E
import qualified Control.Lens as Lens
import           Control.Monad.Trans.FastWriter (writerT)
import           Data.CurAndPrev (current)
import           Data.IORef
import           Data.MRUMemo (memoIO)
import           Data.Property (Property(..))
import qualified Data.Property as Property
import qualified Data.Tuple as Tuple
import qualified GUI.Momentu as M
import qualified GUI.Momentu.Main as MainLoop
import qualified GUI.Momentu.Widget as Widget
import qualified Graphics.Rendering.OpenGL.GL as GL
import qualified Lamdu.Cache as Cache
import           Lamdu.Config (Config)
import qualified Lamdu.Config as Config
import           Lamdu.Config.Sampler (Sampler, sConfig, sTheme)
import qualified Lamdu.Config.Sampler as ConfigSampler
import           Lamdu.Config.Theme (Theme(..))
import qualified Lamdu.Config.Theme as Theme
import           Lamdu.Data.Db.Layout (DbM, ViewM)
import qualified Lamdu.Data.Db.Layout as DbLayout
import           Lamdu.Data.Export.JS (exportFancy)
import qualified Lamdu.Data.Export.JSON as Export
import qualified Lamdu.Debug as Debug
import qualified Lamdu.Eval.Manager as EvalManager
import           Lamdu.Eval.Results (EvalResults)
import           Lamdu.Expr.IRef (ValI)
import           Lamdu.Font (FontSize, Fonts(..))
import qualified Lamdu.Font as Font
import           Lamdu.GUI.IOTrans (ioTrans)
import qualified Lamdu.GUI.IOTrans as IOTrans
import qualified Lamdu.GUI.Main as GUIMain
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Main.Env (Env(..))
import qualified Lamdu.Main.Env as Env
import qualified Lamdu.Opts as Opts
import           Lamdu.Settings (Settings(..))
import qualified Lamdu.Settings as Settings
import           Lamdu.Style (FontInfo(..))
import qualified Lamdu.Style as Style
import           Lamdu.Sugar.Convert.Input (AnnotationMode(..))
import qualified Lamdu.Themes as Themes
import           Revision.Deltum.IRef (IRef)
import           Revision.Deltum.Transaction (Transaction)
import qualified Revision.Deltum.Transaction as Transaction
import           System.FilePath ((</>))
import qualified System.FilePath as FilePath
import qualified System.Metrics as Metrics
import qualified System.Metrics.Distribution as Distribution
import qualified System.Remote.Monitoring.Shim as Ekg

import           Lamdu.Prelude

type T = Transaction

newtype RefreshScheduler = RefreshScheduler (IORef Bool)
newRefreshScheduler :: IO RefreshScheduler
newRefreshScheduler = newIORef False <&> RefreshScheduler
isRefreshScheduled :: RefreshScheduler -> IO Bool
isRefreshScheduled (RefreshScheduler ref) = atomicModifyIORef ref ((,) False)
scheduleRefresh :: RefreshScheduler -> IO ()
scheduleRefresh (RefreshScheduler ref) =
    do
        writeIORef ref True
        MainLoop.wakeUp

stateStorageInIRef :: Transaction.Store DbM -> IRef DbLayout.DbM M.GUIState -> MainLoop.StateStorage
stateStorageInIRef db stateIRef =
    MainLoop.StateStorage
    { readState = DbLayout.runDbTransaction db (Transaction.readIRef stateIRef)
    , writeState = DbLayout.runDbTransaction db . Transaction.writeIRef stateIRef
    }

withMVarProtection :: a -> (MVar (Maybe a) -> IO b) -> IO b
withMVarProtection val =
    E.bracket (newMVar (Just val)) (\mvar -> modifyMVar_ mvar (\_ -> pure Nothing))

newEvaluator ::
    IO () -> MVar (Maybe (Transaction.Store DbM)) -> Opts.EditorOpts -> IO EvalManager.Evaluator
newEvaluator refresh dbMVar opts =
    EvalManager.new EvalManager.NewParams
    { EvalManager.resultsUpdated = refresh
    , EvalManager.dbMVar = dbMVar
    , EvalManager.jsDebugPaths = opts ^. Opts.eoJSDebugPaths
    }

settingsChangeHandler :: Sampler -> EvalManager.Evaluator -> Maybe Settings -> Settings -> IO ()
settingsChangeHandler configSampler evaluator mOld new =
    do
        whenChanged Settings.sAnnotationMode $ \case
            Evaluation -> EvalManager.start evaluator
            _ -> EvalManager.stop evaluator
        whenChanged Settings.sSelectedTheme $ ConfigSampler.setTheme configSampler
    where
        whenChanged lens f =
            case mOld of
            Nothing -> f (new ^. lens)
            Just old -> when (old ^. lens /= new ^. lens) $ f (new ^. lens)

newSettingsProp ::
    Settings -> Sampler -> EvalManager.Evaluator -> IO (IO (Property IO Settings))
newSettingsProp initial configSampler evaluator =
    do
        settingsRef <- newIORef initial
        let setSettings val =
                do
                    oldVal <- readIORef settingsRef
                    writeIORef settingsRef val
                    settingsChangeHandler configSampler evaluator (Just oldVal) val
        settingsChangeHandler configSampler evaluator Nothing initial
        readIORef settingsRef <&> (`Property` setSettings) & pure

createWindow :: String -> Opts.WindowMode -> IO M.Window
createWindow title mode =
    do
        monitor <-
            M.getPrimaryMonitor
            >>= maybe (fail "GLFW: Can't get primary monitor") pure
        videoModeSize <- M.getVideoModeSize monitor
        let createWin = M.createWindow title
        case mode of
            Opts.FullScreen         -> createWin (Just monitor) videoModeSize
            Opts.VideoModeSize      -> createWin Nothing (videoModeSize - 1)

printGLVersion :: IO ()
printGLVersion =
    do
        ver <- GL.get GL.glVersion
        putStrLn $ "Using GL version: " ++ show ver

prependConfigPath :: ConfigSampler.Sample -> Fonts FilePath -> Fonts FilePath
prependConfigPath sample =
    Lens.mapped %~ f
    where
        dir = FilePath.takeDirectory (sample ^. ConfigSampler.sConfigPath)
        f "" = "" -- Debug font!
        f x = dir </> x

assignFontSizes :: Theme -> Fonts FilePath -> Fonts (FontSize, FilePath)
assignFontSizes theme fonts =
    fonts
    <&> (,) baseTextSize
    & Font.fontHelp . _1 .~ helpTextSize
    where
        baseTextSize = theme ^. Theme.baseTextSize
        helpTextSize = theme ^. Theme.help . Theme.helpTextSize

curSampleFonts :: ConfigSampler.Sample -> Fonts (FontSize, FilePath)
curSampleFonts sample =
    sample ^. sTheme . Theme.fonts
    & prependConfigPath sample
    & assignFontSizes (sample ^. sTheme)

makeGetFonts ::
    Font.LCDSubPixelEnabled ->
    IO (M.Zoom -> ConfigSampler.Sample -> IO (Fonts M.Font))
makeGetFonts subpixel =
    Font.new subpixel & uncurry & memoIO
    <&> f
    where
        f cachedLoadFonts zoom sample =
            do
                sizeFactor <- M.getZoomFactor zoom
                cachedLoadFonts
                    ( ConfigSampler.defaultFontPath sample
                    , curSampleFonts sample <&> _1 *~ sizeFactor
                    )

makeReportPerfCounters :: Ekg.Server -> IO (MainLoop.PerfCounters -> IO ())
makeReportPerfCounters ekg =
    do
        renderDist <- Metrics.createDistribution "Render time" store
        swapDist <- Metrics.createDistribution "SwapBuffers time" store
        pure $ \(MainLoop.PerfCounters renderTime swapBufferTime) ->
            do
                Distribution.add renderDist renderTime
                Distribution.add swapDist swapBufferTime
    where
        store = Ekg.serverMetricStore ekg

mainLoop ::
    Maybe Ekg.Server -> MainLoop.StateStorage -> Font.LCDSubPixelEnabled ->
    M.Window -> RefreshScheduler -> Sampler ->
    (Fonts M.Font -> Config -> Theme -> MainLoop.Env ->
    IO (M.Widget (MainLoop.M IO M.Update))) -> IO ()
mainLoop ekg stateStorage subpixel win refreshScheduler configSampler iteration =
    do
        getFonts <- makeGetFonts subpixel
        lastVersionNumRef <- newIORef []
        let makeWidget env =
                do
                    sample <- ConfigSampler.getSample configSampler
                    when (sample ^. sConfig . Config.debug . Config.printCursor)
                        (putStrLn ("Cursor: " <> show (env ^. M.cursor)))
                    fonts <- getFonts (env ^. MainLoop.eZoom) sample
                    iteration fonts (sample ^. sConfig) (sample ^. sTheme) env
        let mkFontInfo zoom =
                do
                    sample <- ConfigSampler.getSample configSampler
                    getFonts zoom sample
                        <&> (^. Font.fontDefault) <&> Font.height <&> FontInfo
        let mkConfigTheme =
                ConfigSampler.getSample configSampler
                <&> \sample -> (sample ^. sConfig, sample ^. sTheme)
        reportPerfCounters <- traverse makeReportPerfCounters ekg
        M.mainLoopWidget win makeWidget MainLoop.Options
            { config = Style.mainLoopConfig mkFontInfo mkConfigTheme
            , tickHandler =
                do
                    sample <- ConfigSampler.getSample configSampler
                    let curVersionNum = ConfigSampler.sVersion sample
                    configChanged <- atomicModifyIORef lastVersionNumRef $
                        \lastVersionNum ->
                        (curVersionNum, lastVersionNum /= curVersionNum)
                    if configChanged
                        then pure True
                        else isRefreshScheduled refreshScheduler
            , stateStorage = stateStorage
            , debug = MainLoop.DebugOptions
                { fpsFont =
                  \zoom ->
                  do
                      sample <- ConfigSampler.getSample configSampler
                      if sample ^. sConfig . Config.debug . Config.debugShowFPS
                          then getFonts zoom sample <&> (^. Font.fontDebugInfo) <&> Just
                          else pure Nothing
                , virtualCursorColor =
                    ConfigSampler.getSample configSampler
                    <&> (^. sConfig . Config.debug . Config.virtualCursorShown)
                    <&> \case
                        False -> Nothing
                        True -> Just (M.Color 1 1 0 0.5)
                , reportPerfCounters = fromMaybe (const (pure ())) reportPerfCounters
                }
            }

makeMainGui ::
    HasCallStack =>
    [Themes.Selection] -> Property IO Settings ->
    (forall a. T DbLayout.DbM a -> IO a) ->
    Env -> T DbLayout.DbM (M.Widget (MainLoop.M IO M.Update))
makeMainGui themeNames settingsProp dbToIO env =
    GUIMain.make themeNames settingsProp env
    <&> Lens.mapped %~
    \act ->
    act ^. ioTrans . Lens._Wrapped
    <&> (^. Lens._Wrapped)
    <&> dbToIO
    & join
    <&> Tuple.swap
    & writerT

mkWidgetWithFallback ::
    HasCallStack =>
    Property IO Settings ->
    (forall a. T DbLayout.DbM a -> IO a) ->
    Env -> IO (M.Widget (MainLoop.M IO M.Update))
mkWidgetWithFallback settingsProp dbToIO env =
    do
        themeNames <- Themes.getNames
        let tryMakeGui = makeMainGui themeNames settingsProp dbToIO
        (isValid, widget) <-
            dbToIO $
            do
                candidateWidget <- tryMakeGui env
                (isValid, widget) <-
                    if M.isFocused candidateWidget
                    then pure (True, candidateWidget)
                    else
                        env & M.cursor .~ WidgetIds.defaultCursor
                        & tryMakeGui <&> (,) False
                unless (M.isFocused widget) $
                    fail "Root cursor did not match"
                pure (isValid, widget)
        unless isValid $ putStrLn $ "Invalid cursor: " ++ show (env ^. M.cursor)
        widget
            & M.backgroundColor (["background"] :: M.AnimId) (theme ^. bgColor isValid)
            & pure
    where
        theme = env ^. Env.theme
        bgColor False = Theme.invalidCursorBGColor
        bgColor True = Theme.backgroundColor

exportActions ::
    Config -> EvalResults (ValI ViewM) -> IO () -> GUIMain.ExportActions ViewM
exportActions config evalResults executeIOProcess =
    GUIMain.ExportActions
    { GUIMain.exportReplActions =
        GUIMain.ExportRepl
        { GUIMain.exportRepl = fileExport Export.fileExportRepl
        , GUIMain.exportFancy = exportFancy evalResults & execTIO
        , GUIMain.executeIOProcess = executeIOProcess
        }
    , GUIMain.exportAll = fileExport Export.fileExportAll
    , GUIMain.exportDef = fileExport . Export.fileExportDef
    , GUIMain.importAll = importAll
    }
    where
        exportPath = config ^. Config.export . Config.exportPath
        execTIO = IOTrans.liftTExecInMain . fmap MainLoop.ExecuteInMainThread
        fileExport exporter = exporter exportPath & execTIO
        importAll path = Export.fileImportAll path & IOTrans.liftIOT

makeRootWidget ::
    HasCallStack =>
    Cache.Functions -> Debug.Monitors -> Fonts M.Font ->
    Transaction.Store DbM -> EvalManager.Evaluator -> Config -> Theme ->
    MainLoop.Env -> Property IO Settings ->
    IO (M.Widget (MainLoop.M IO M.Update))
makeRootWidget cachedFunctions perfMonitors fonts db evaluator config theme mainLoopEnv settingsProp =
    do
        evalResults <- EvalManager.getResults evaluator
        let env = Env
                { _evalRes = evalResults
                , _exportActions =
                    exportActions config
                    (evalResults ^. current)
                    (EvalManager.executeReplIOProcess evaluator)
                , _config = config
                , _theme = theme
                , _settings = Property.value settingsProp
                , _style = Style.make fonts theme
                , _mainLoop = mainLoopEnv
                , _animIdPrefix = mempty
                , _debugMonitors = monitors
                , _cachedFunctions = cachedFunctions
                }
        let dbToIO action =
                case settingsProp ^. Property.pVal . Settings.sAnnotationMode of
                Evaluation ->
                    EvalManager.runTransactionAndMaybeRestartEvaluator evaluator action
                _ -> DbLayout.runDbTransaction db action
        let measureLayout w =
                -- Hopefully measuring the forcing of these is enough to figure out the layout -
                -- it's where's the cursors at etc.
                report w
                & Widget.wState . Widget._StateFocused . Lens.mapped %~ f
                where
                    Debug.Evaluator report = monitors ^. Debug.layout . Debug.mPure
                    f x = report ((x ^. Widget.fFocalAreas) `deepseq` x)
        mkWidgetWithFallback settingsProp dbToIO env
            <&> measureLayout
    where
        monitors = Debug.addBreakPoints (config ^. Config.debug . Config.breakpoints) perfMonitors

run :: HasCallStack => Opts.EditorOpts -> Transaction.Store DbM -> IO ()
run opts rawDb =
    do
        refreshScheduler <- newRefreshScheduler
        let refresh = scheduleRefresh refreshScheduler
        ekg <- traverse Ekg.start (opts ^. Opts.eoEkgPort)
        monitors <-
            traverse Debug.makeCounters ekg
            >>= maybe (pure Debug.noopMonitors) Debug.makeMonitors
        configSampler <-
            ConfigSampler.new (const refresh) (Settings.initial ^. Settings.sSelectedTheme)
        (cache, cachedFunctions) <- Cache.make
        let Debug.EvaluatorM reportDb = monitors ^. Debug.database . Debug.mAction
        let db = Transaction.onStoreM reportDb rawDb
        let stateStorage = stateStorageInIRef db DbLayout.guiState
        withMVarProtection db $
            \dbMVar ->
            do
                -- Load config as early as possible, before we open any windows/etc
                evaluator <- newEvaluator refresh dbMVar opts
                mkSettingsProp <- newSettingsProp Settings.initial configSampler evaluator
                M.withGLFW $ do
                    win <-
                        createWindow
                        (opts ^. Opts.eoWindowTitle)
                        (opts ^. Opts.eoWindowMode)
                    printGLVersion
                    mainLoop ekg stateStorage subpixel win refreshScheduler configSampler $
                        \fonts config theme env ->
                        Cache.fence cache *>
                        mkSettingsProp
                        >>= makeRootWidget cachedFunctions monitors fonts db evaluator config theme env
    where
        subpixel
            | opts ^. Opts.eoSubpixelEnabled = Font.LCDSubPixelEnabled
            | otherwise = Font.LCDSubPixelDisabled
{-# LANGUAGE MultiWayIf #-}

{- |
Copyright   : (c) Runtime Verification, 2018-2022
License     : BSD-3-Clause
Maintainer  : jost.berthold@runtimeverification.com
-}
module Kore.Exec.GraphTraversal (
    graphTraversal,
    simpleTransition,
    TState (..),
    TransitionResult (..),
    TraversalResult (..),
    transitionWithRule,
    GraphTraversalTimeoutMode (..),
    StuckTraversalResult (..),
    extractStuckTraversalResult,
) where

import Control.Concurrent (
    MVar,
    newEmptyMVar,
    threadDelay,
 )
import Control.Concurrent.Async.Lifted (
    race,
    withAsync,
 )
import Control.Exception.Lifted (uninterruptibleMask_)
import Control.Monad (foldM)
import Control.Monad.Extra (whenJust)
import Control.Monad.Trans.State
import Data.Limit
import Data.List.NonEmpty qualified as NE
import Data.Maybe (fromJust)
import Data.Sequence (Seq (..))
import Data.Sequence qualified as Seq
import Debug (Debug, Diff)
import GHC.Generics qualified
import GHC.Natural
import Generics.SOP qualified as SOP
import Kore.Log.WarnStepTimeout (
    warnStepMATimeout,
    warnStepManualTimeout,
 )
import Kore.Rewrite.Strategy (
    FinalNodeType (..),
    GraphSearchOrder (..),
    LimitExceeded (..),
    Step,
    unfoldSearchOrder,
 )
import Kore.Rewrite.Timeout (
    EnableMovingAverage,
    StepMovingAverage,
    StepTimeout,
    TimeoutMode (..),
    getTimeout,
    getTimeoutMode,
    timeAction,
    updateStepMovingAverage,
 )
import Kore.Rewrite.Transition (
    TransitionT (..),
    runTransitionT,
 )
import Kore.Simplify.Simplify (Simplifier)
import Prelude.Kore
import Pretty
import System.IO (
    hPutStrLn,
    stderr,
 )

data TransitionResult a
    = -- | straight-line execution
      Continuing a
    | -- | branch point (1st arg), branching into 2nd arg elements
      Branch a (NonEmpty a)
    | -- | no next state but not final (e.g., not goal state, or side
      -- conditions do not hold)
      Stuck a
    | -- | the current configuration was simplified to bottom
      Vacuous a
    | -- | final state (e.g., goal state reached, side conditions hold)
      Final a
    | -- | not stuck, but also not final (maximum depth reached before
      -- finishing the proof). Provides current and "next" states for the result.
      Stop a [a]
    deriving stock (Eq, Show)

instance Functor TransitionResult where
    fmap f = \case
        Continuing a -> Continuing $ f a
        Branch a as -> Branch (f a) $ NE.map f as
        Stuck a -> Stuck $ f a
        Vacuous a -> Vacuous $ f a
        Final a -> Final $ f a
        Stop a as -> Stop (f a) (map f as)

instance Pretty a => Pretty (TransitionResult a) where
    pretty = \case
        Continuing a -> single "Continuing" a
        Branch a as -> multi "Branch" "node" a "successors" (NE.toList as)
        Stuck a -> single "Stuck" a
        Vacuous a -> single "Vacuous" a
        Final a -> single "Final" a
        Stop a as -> multi "Stop" "node" a "successors" as
      where
        single :: Doc x -> a -> Doc x
        single lbl a =
            Pretty.vsep [lbl, Pretty.indent 4 $ Pretty.pretty a]

        multi :: Doc x -> Doc x -> a -> Doc x -> [a] -> Doc x
        multi lbl lbl1 a lbl2 as =
            Pretty.vsep $
                [ lbl
                , Pretty.indent 2 $ "- " <> lbl1
                , Pretty.indent 4 $ Pretty.pretty a
                , Pretty.indent 2 $ "- " <> lbl2
                ]
                    <> map (Pretty.indent 4 . Pretty.pretty) as

isStuckOrVacuous, isFinal, isStop, isBranch :: TransitionResult a -> Bool
isStuckOrVacuous (Stuck _) = True
isStuckOrVacuous (Vacuous _) = True
isStuckOrVacuous _ = False
isFinal (Final _) = True
isFinal _ = False
isStop (Stop _ _) = True
isStop _ = False
isBranch (Branch _ _) = True
isBranch _ = False

extractNext :: TransitionResult a -> [a]
extractNext = \case
    Continuing a -> [a]
    Branch _ as -> NE.toList as
    Stuck _ -> []
    Vacuous _ -> []
    Final _ -> []
    Stop _ as -> as

extractState :: TransitionResult a -> Maybe a
extractState = \case
    Continuing _ -> Nothing
    Branch a _ -> Just a
    Stuck a -> Just a
    Vacuous a -> Just a
    Final a -> Just a
    Stop a _ -> Just a

extractStuckOrVacuous :: TransitionResult a -> Maybe (StuckTraversalResult a)
extractStuckOrVacuous = \case
    Stuck a -> Just $ IsStuck a
    Vacuous a -> Just $ IsVacuous a
    _ -> Nothing

{- | The traversal state, including subsequent steps to take in the
   traversal.
-}
data TState instr config = TState
    { nextSteps :: [Step instr]
    -- ^ remaining steps available for the traversal
    , currentState :: config
    -- ^ current configuration (i.e., claim or program state)
    }

----------------------------------------

{- | Perform a traversal of a graph of configurations, with rewrites,
   simplifications, and (maybe) checks as the transitions.

  The transition function operates on a traversal state @'TState'@
  which holds a @currentState@ configuration as well as
  @nextSteps@, "instructions" to indicate what kind of transition to
  perform next, and in "steps" that consist of one or more of these
  instructions.

  Transition yields a @'TransitionResult'@ which indicates what to do
  next. The reached configuration could be @'Final'@ or @'Stuck'@, or
  traversal should be @'Stop'@ped. Otherwise, traversal continues,
  either simply @'Continuing'@ with a next state, or @'Branch'@ing
  (i.e., continuing on several branches).

  These alternatives are the different constructors of
  @'TransitionResult'@.

  The return type @'TraversalResult'@ describes the outcome of the
  whole traversal.

  A traversal ends normally with @'Ended'@ when all branches of the
  traversal found @'Final'@ configurations within the provided
  instruction steps.

  When any @'Stuck'@ configurations were found, the traversal result
  will be @'GotStuck'@, including those stuck configurations and the
  remaining queue length (@> 0@ in case traversal was stopped
  prematurely after having found the maximum of counterexamples given
  as a parameter).

  When any transition produced @'Stop'@, or when stopping at branch
  points was requested, the result will include non-final states. In
  this case, the result is @'Stopped'@, returning all non-final states
  and their successors.

  Note that the transition function can modify the provided
  instructions during the traversal. Usually the @nextSteps@ in
  traversal state @'TState'@ would be consumed one @'Step'@ at a time
  but this is not required.
-}
graphTraversal ::
    forall config instr.
    GraphTraversalTimeoutMode ->
    Maybe StepTimeout ->
    EnableMovingAverage ->
    -- | Whether to stop on branches or not. This could be handled in
    -- the transition function, too, since the algorithm will _always_
    -- stop on 'Stuck', 'Final', and `Stopped`. It is clearer to add
    -- this explicitly here, though.
    FinalNodeType ->
    -- queue updating parameters,
    -- we construct enqueue :: [a] -> Seq a -> m (Either LimitExceeded (Seq a)) from it

    -- | BreadthFirst, DepthFirst
    GraphSearchOrder ->
    -- | breadth limit, essentially a natural number
    Limit Natural ->
    -- | transition function
    ( TState instr config ->
      Simplifier (TransitionResult (TState instr config))
    ) ->
    -- | config unparsing function
    (config -> Maybe String) ->
    -- | max-counterexamples, included in the internal logic
    Limit Natural ->
    -- | steps to execute
    [Step instr] ->
    -- | initial state
    config ->
    Simplifier (TraversalResult config)
graphTraversal
    graphTraversalTimeoutMode
    timeout
    enableMA
    stopOn
    direction
    breadthLimit
    transit
    unparseConfig
    maxCounterExamples
    steps
    start = do
        ma <- liftIO newEmptyMVar
        enqueue [TState steps start] Seq.empty
            >>= either
                (pure . const (GotStuck 0 [IsStuck start]))
                (\q -> evalStateT (worker ma q >>= checkLeftUnproven) [])
      where
        enqueue' = unfoldSearchOrder direction

        enqueue ::
            [TState instr config] ->
            Seq (TState instr config) ->
            Simplifier
                ( Either
                    (LimitExceeded (TState instr config))
                    (Seq (TState instr config))
                )
        enqueue as q = do
            newQ <- enqueue' as q
            pure $
                if exceedsLimit newQ
                    then Left (LimitExceeded newQ)
                    else Right newQ

        exceedsLimit :: Seq a -> Bool
        exceedsLimit =
            not . withinLimit breadthLimit . fromIntegral . Seq.length

        -- when stopping at branches, turn a 'Branch' result into a 'Stopped'
        branchStop :: TransitionResult (TState i c) -> TransitionResult (TState i c)
        branchStop result
            | isBranch result =
                case stopOn of
                    Leaf -> result
                    LeafOrBranching ->
                        Stop (fromJust $ extractState result) (extractNext result)
            | otherwise = result

        worker ::
            MVar StepMovingAverage ->
            Seq (TState instr config) ->
            StateT
                [TransitionResult (TState instr config)]
                Simplifier
                (TraversalResult (TState instr config))
        worker _ Seq.Empty = Ended . reverse <$> gets (mapMaybe extractState)
        worker ma (a :<| as) = do
            result <- lift $ withTimeout ma a as $ step a as
            case result of
                Continue nextQ -> worker ma nextQ
                Output oneResult nextQ -> do
                    modify (oneResult :)
                    if not (isStuckOrVacuous oneResult)
                        then worker ma nextQ
                        else do
                            stuck <- gets (filter isStuckOrVacuous)
                            if maxCounterExamples <= Limit (fromIntegral (length stuck))
                                then
                                    pure $
                                        GotStuck (Seq.length nextQ) (mapMaybe extractStuckOrVacuous stuck)
                                else worker ma nextQ
                Abort _lastState queue -> do
                    pure $ Aborted $ toList queue
                Timeout lastState queue -> pure $ TimedOut lastState $ toList queue

        withTimeout ma stepState stepQueue execStep =
            getTimeoutMode timeout enableMA ma >>= \case
                Nothing -> execStep
                Just timeoutMode ->
                    case graphTraversalTimeoutMode of
                        GraphTraversalWarn -> do
                            let warnThread = do
                                    liftIO . threadDelay $ getTimeout timeoutMode
                                    uninterruptibleMask_ $ do
                                        case timeoutMode of
                                            ManualTimeout t -> warnStepManualTimeout t
                                            MovingAverage t -> warnStepMATimeout t
                                        whenJust (unparseConfig $ currentState stepState) $
                                            \config ->
                                                liftIO . hPutStrLn stderr $
                                                    "// Last configuration:\n" <> config
                            withAsync warnThread (const $ timeAction execStep)
                                >>= \(time, stepResult) -> do
                                    updateStepMovingAverage ma time
                                    pure stepResult
                        GraphTraversalCancel -> do
                            let warnThread =
                                    liftIO $
                                        threadDelay $
                                            getTimeout timeoutMode
                            race warnThread (timeAction execStep) >>= \case
                                Right (time, stepResult) -> do
                                    updateStepMovingAverage ma time
                                    pure stepResult
                                Left _ -> pure $ Timeout stepState stepQueue

        step ::
            (TState instr config) ->
            Seq (TState instr config) ->
            Simplifier (StepResult (TState instr config))
        step a q = do
            next <- branchStop <$> transit a
            if (isStuckOrVacuous next || isFinal next || isStop next)
                then pure (Output next q)
                else
                    let abort (LimitExceeded queue) = Abort next queue
                     in either abort Continue <$> enqueue (extractNext next) q

        checkLeftUnproven ::
            TraversalResult (TState instr config) ->
            StateT
                [TransitionResult (TState instr config)]
                Simplifier
                (TraversalResult config)
        checkLeftUnproven = \case
            result@(Ended{}) -> do
                collected <- gets reverse
                -- we collect a maximum of 'maxCounterExamples' Stuck states
                let stuck = map (fmap currentState) $ filter isStuckOrVacuous collected
                -- Other states may be unfinished but not stuck (Stop)
                -- Only provide the requested amount of states (maxCounterExamples)
                let unproven =
                        takeWithin maxCounterExamples . map (fmap currentState) $
                            filter isStop collected
                pure $
                    if
                        | (not $ null stuck) ->
                            GotStuck 0 (mapMaybe extractStuckOrVacuous stuck)
                        | not $ null unproven ->
                            Stopped
                                (mapMaybe extractState unproven)
                                (concatMap extractNext unproven)
                        | otherwise -> fmap currentState result
            other -> pure $ fmap currentState other

{- | Used to select whether the step should be canceled
 when the timeout is reached or not.
-}
data GraphTraversalTimeoutMode
    = -- | Cancel step on timeout, used in `kore-rpc`
      GraphTraversalCancel
    | -- | Warn on timeout, used in `kore-exec`
      GraphTraversalWarn

data StepResult a
    = -- | Traversal continues with given queue.
      Continue (Seq a)
    | -- | Traversal produced a result and continues with given queue.
      -- Typically a final or stuck state (or a "stop" state), and the
      -- queue is the remaining work.
      Output (TransitionResult a) (Seq a)
    | -- | Traversal exceeded the breadth limit and should not
      -- continue. The last state and the current queue are provided
      -- for analysis.
      Abort (TransitionResult a) (Seq a)
    | -- | Traversal step exceeded timeout limit.
      Timeout a (Seq a)
    deriving stock (Eq, Show)

data StuckTraversalResult a = IsStuck a | IsVacuous a
    deriving stock (Eq, Show)
    deriving stock (GHC.Generics.Generic, Functor)
    deriving anyclass (SOP.Generic, SOP.HasDatatypeInfo)

instance Debug a => Debug (StuckTraversalResult a)
instance (Debug a, Diff a) => Diff (StuckTraversalResult a)

instance Pretty a => Pretty (StuckTraversalResult a) where
    pretty = \case
        IsStuck a -> pretty a
        IsVacuous a -> "(vacuous)" <+> pretty a

extractStuckTraversalResult :: StuckTraversalResult a -> a
extractStuckTraversalResult = \case
    IsStuck a -> a
    IsVacuous a -> a

data TraversalResult a
    = -- | remaining queue length and stuck results (always at most
      -- maxCounterExamples many).
      GotStuck Int [StuckTraversalResult a]
    | -- | queue (length exceeding the limit), including result(s) of
      -- the last step that led to stopping.
      Aborted [a]
    | -- | queue empty, results returned
      Ended [a]
    | -- | stop was signalled by the transition, return stopped
      -- (unproven) states and next states (from queue)
      Stopped [a] [a]
    | -- | timed out, return current state and next states
      TimedOut a [a]
    deriving stock (Eq, Show)
    deriving stock (GHC.Generics.Generic)
    deriving anyclass (SOP.Generic, SOP.HasDatatypeInfo)

instance Debug a => Debug (TraversalResult a)
instance (Debug a, Diff a) => Diff (TraversalResult a)

instance Pretty a => Pretty (TraversalResult a) where
    pretty = \case
        GotStuck n as ->
            Pretty.hang 4 . Pretty.vsep $
                ("Got stuck with queue of " <> Pretty.pretty n)
                    : map Pretty.pretty as
        Aborted as ->
            Pretty.hang 4 . Pretty.vsep $
                "Aborted with queue of "
                    : map Pretty.pretty as
        Ended as ->
            Pretty.hang 4 . Pretty.vsep $
                "Ended" : map Pretty.pretty as
        Stopped as qu ->
            Pretty.hang 4 . Pretty.vsep $
                ("Stopped" : map Pretty.pretty as)
                    <> ("Queue" : map Pretty.pretty qu)
        TimedOut as qu ->
            Pretty.hang 4 . Pretty.vsep $
                ("Timed out" <> Pretty.pretty as)
                    : ("Queue" : map Pretty.pretty qu)
instance Functor TraversalResult where
    fmap f = \case
        GotStuck n rs -> GotStuck n (map (fmap f) rs)
        Aborted rs -> Aborted (map f rs)
        Ended rs -> Ended (map f rs)
        Stopped rs qu -> Stopped (map f rs) (map f qu)
        TimedOut rs qu -> TimedOut (f rs) (map f qu)

----------------------------------------
-- constructing transition functions (for caller)

{- | Construct a transit function for the traversal from its primitive
 steps @prim@ and an interpretation of resulting next states to
 yield a @TransitionResult@.
-}
simpleTransition ::
    forall config m instr rule.
    Monad m =>
    -- | primitive transition applying a rule
    (instr -> config -> TransitionT rule m config) ->
    -- | interprets the config (claim or program state) and rules
    (config -> [config] -> TransitionResult config) ->
    TState instr config ->
    m (TransitionResult (TState instr config))
simpleTransition apply mapToResult = tt
  where
    tt :: TState instr config -> m (TransitionResult (TState instr config))
    tt TState{nextSteps, currentState = config} =
        case nextSteps of
            [] ->
                pure $ fmap (TState []) $ mapToResult config []
            [] : iss ->
                tt $ TState iss config
            is : iss ->
                (fmap (TState iss) . mapToResult config . map fst)
                    <$> runTransitionT (foldM (flip apply) config is)

{- | Construct a transit function for the traversal from its primitive
 steps @prim@ and an interpretation of resulting next states _and
 applied rules_ to yield a @TransitionResult@.

 The rule can be considered to implement e.g. stopping when a
 particular rule (such as unrolling a loop) has been applied.
-}

{- | Construct a transit function for the traversal from its primitive
 steps @prim@ and an interpretation of resulting next states _and
 applied rules_ to yield a @TransitionResult@.

 The rule can be considered to implement e.g. stopping when a
 particular rule (such as unrolling a loop) has been applied.
-}
transitionWithRule ::
    forall config m instr rule.
    Monad m =>
    -- | primitive transition applying a rule
    (instr -> config -> TransitionT rule m config) ->
    -- | interprets the config (claim or program state) and rules
    (config -> [(config, Seq rule)] -> TransitionResult config) ->
    TState instr config ->
    m (TransitionResult (TState instr config))
transitionWithRule apply mapToResult = tt
  where
    tt :: TState instr config -> m (TransitionResult (TState instr config))
    tt TState{nextSteps, currentState = config} =
        case nextSteps of
            [] ->
                pure $ fmap (TState []) $ mapToResult config []
            [] : iss ->
                tt $ TState iss config
            is : iss ->
                (fmap (TState iss) . mapToResult config)
                    <$> runTransitionT (foldM (flip apply) config is)

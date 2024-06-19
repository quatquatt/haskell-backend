{-# LANGUAGE TemplateHaskell #-}

{- |
Copyright   : (c) Runtime Verification, 2019-2021
License     : BSD-3-Clause

Unification of rules (used for stepping with rules or equations)
-}
module Kore.Rewrite.Step (
    UnifiedRule,
    Result,
    Results,
    Renaming,
    UnifyingRule (..),
    InstantiationFailure (..),
    unifyRules,
    unifyRule,
    applyInitialConditions,
    simplifyRemainder,
    applyRemainder,
    assertFunctionLikeResults,
    checkFunctionLike,
    wouldNarrowWith,

    -- * Re-exports
    mkRewritingPattern,
    -- Below exports are just for tests
    Step.gatherResults,
    Step.remainders,
    Step.result,
    Step.results,
) where

import Data.Map.Strict qualified as Map
import Data.Set (
    Set,
 )
import Data.Set qualified as Set
import Kore.Attribute.Label (
    Label (..),
 )
import Kore.Attribute.Pattern.FreeVariables qualified as FreeVariables
import Kore.Attribute.SourceLocation (
    SourceLocation,
 )
import Kore.Attribute.UniqueId (
    UniqueId (..),
 )
import Kore.Internal.Condition (
    Condition,
 )
import Kore.Internal.Condition qualified as Condition
import Kore.Internal.Conditional (
    Conditional (Conditional),
 )
import Kore.Internal.Conditional qualified as Conditional
import Kore.Internal.MultiOr qualified as MultiOr
import Kore.Internal.Pattern (
    Pattern,
 )
import Kore.Internal.Pattern qualified as Pattern
import Kore.Internal.SideCondition (
    SideCondition,
 )
import Kore.Internal.SideCondition qualified as SideCondition
import Kore.Internal.Substitution qualified as Substitution
import Kore.Internal.TermLike (
    InternalVariable,
    SomeVariableName,
    TermLike,
 )
import Kore.Internal.TermLike qualified as TermLike
import Kore.Log.DebugAppliedRewriteRules (
    debugAppliedLabeledRewriteRule,
 )
import Kore.Log.DebugAttemptedRewriteRules (
    whileDebugAttemptRewriteRule,
 )
import Kore.Log.DebugContext (inContext)
import Kore.Log.DecidePredicateUnknown (srcLoc)
import Kore.Rewrite.Result qualified as Result
import Kore.Rewrite.Result qualified as Results
import Kore.Rewrite.Result qualified as Step
import Kore.Rewrite.RewritingVariable
import Kore.Rewrite.SMT.Evaluator qualified as SMT.Evaluator
import Kore.Rewrite.UnifyingRule
import Kore.Simplify.Simplify (
    Simplifier,
    liftSimplifier,
 )
import Kore.Simplify.Simplify qualified as Simplifier
import Kore.Unification.NewUnifier (
    NewUnifier,
 )
import Kore.Unification.Procedure
import Kore.Unparser
import Logic (
    LogicT,
 )
import Logic qualified
import Prelude.Kore
import Pretty qualified

type UnifiedRule rule = Conditional (UnifyingRuleVariable rule) rule

type Result rule =
    Step.Result
        (UnifiedRule rule)
        (Pattern (UnifyingRuleVariable rule))

type Results rule =
    Step.Results
        (UnifiedRule rule)
        (Pattern (UnifyingRuleVariable rule))

-- | Unifies/matches a list a rules against a configuration. See 'unifyRule'.
unifyRules ::
    UnifyingRule rule =>
    UnifyingRuleVariable rule ~ RewritingVariableName =>
    From rule SourceLocation =>
    From rule Label =>
    From rule UniqueId =>
    -- | SideCondition containing metadata
    SideCondition RewritingVariableName ->
    -- | Initial configuration
    Pattern RewritingVariableName ->
    -- | Rule
    [rule] ->
    Simplifier [UnifiedRule rule]
unifyRules sideCondition initial rules =
    runUnifier
        ( do
            marker "Rules" ""
            rule <- Logic.scatter rules
            marker "Rule" ""
            unifyRule sideCondition initial rule
        )
        <* marker "EndRules" ""

{- | Attempt to unify a rule with the initial configuration.

The rule variables are renamed to avoid collision with the configuration. The
rule's 'RulePattern.requires' clause is combined with the unification
solution. The combined condition is simplified and checked for
satisfiability.

If any of these steps produces an error, then @unifyRule@ returns that error.

@unifyRule@ returns the renamed rule wrapped with the combined conditions on
unification. The substitution is not applied to the renamed rule.
-}
unifyRule ::
    RewritingVariableName ~ UnifyingRuleVariable rule =>
    UnifyingRule rule =>
    From rule SourceLocation =>
    From rule Label =>
    From rule UniqueId =>
    -- | SideCondition containing metadata
    SideCondition RewritingVariableName ->
    -- | Initial configuration
    Pattern RewritingVariableName ->
    -- | Rule
    rule ->
    NewUnifier (UnifiedRule rule)
unifyRule sideCondition initial rule = do
    let maybeLabel = unLabel . from $ rule
        ruleId = from rule
    whileDebugAttemptRewriteRule initial ruleId maybeLabel location $ do
        ruleMarker "Init"
        let (initialTerm, initialCondition) = Pattern.splitTerm initial
            sideCondition' =
                sideCondition
                    & SideCondition.addConditionWithReplacements initialCondition
        -- Unify the left-hand side of the rule with the term of the initial
        -- configuration.
        let ruleLeft = matchingPattern rule
        ruleMarker "Unify"
        unification <-
            unificationProcedure sideCondition' initialTerm ruleLeft
        -- Combine the unification solution with the rule's requirement clause,
        ruleMarker "CheckSide"
        let ruleRequires = precondition rule
            requires' = Condition.fromPredicate ruleRequires
        unification' <-
            inContext "constraint" $
                Simplifier.simplifyCondition
                    sideCondition'
                    (unification <> requires')
        debugAppliedLabeledRewriteRule initial maybeLabel location
        ruleMarker "Success"
        return (rule `Conditional.withCondition` unification')
  where
    location = from @_ @SourceLocation rule

    locString =
        Pretty.renderString
            . Pretty.layoutCompact
            . Pretty.pretty
            $ location

    ruleMarker tag = marker tag locString

marker :: MonadIO m => String -> String -> m ()
marker tag extra =
    liftIO . traceMarkerIO $ concat ["unify:", tag, ":", extra]

-- | The 'Set' of variables that would be introduced by narrowing.

-- TODO (thomas.tuegel): Unit tests
wouldNarrowWith ::
    forall rule variable.
    variable ~ UnifyingRuleVariable rule =>
    Ord variable =>
    UnifyingRule rule =>
    UnifiedRule rule ->
    Set (SomeVariableName variable)
wouldNarrowWith unified =
    Set.difference leftAxiomVariables substitutionVariables
  where
    leftAxiomVariables =
        TermLike.freeVariables leftAxiom
            & FreeVariables.toNames
      where
        Conditional{term = axiom} = unified
        leftAxiom = matchingPattern axiom
    Conditional{substitution} = unified
    substitutionVariables = Map.keysSet (Substitution.toMap substitution)

-- | Errors if configuration or matching pattern are not function-like
assertFunctionLikeResults ::
    variable ~ UnifyingRuleVariable rule =>
    InternalVariable variable =>
    Monad m =>
    UnifyingRule rule =>
    Eq rule =>
    TermLike variable ->
    Results rule ->
    m ()
assertFunctionLikeResults termLike results =
    let appliedRules = Result.appliedRule <$> Results.results results
     in case checkFunctionLike appliedRules termLike of
            Left err -> error err
            _ -> return ()

-- | Checks whether configuration and matching pattern are function-like
checkFunctionLike ::
    forall variable rule f.
    InternalVariable variable =>
    InternalVariable (UnifyingRuleVariable rule) =>
    Foldable f =>
    UnifyingRule rule =>
    Eq (f (UnifiedRule rule)) =>
    Monoid (f (UnifiedRule rule)) =>
    f (UnifiedRule rule) ->
    TermLike variable ->
    Either String ()
checkFunctionLike unifiedRules pat
    | unifiedRules == mempty = pure ()
    | TermLike.isFunctionPattern pat =
        traverse_ checkFunctionLikeRule unifiedRules
    | otherwise =
        Left . show . Pretty.vsep $
            [ "Expected function-like term, but found:"
            , Pretty.indent 4 (unparse pat)
            ]
  where
    checkFunctionLikeRule ::
        UnifiedRule rule ->
        Either String ()
    checkFunctionLikeRule Conditional{term, substitution}
        | all (TermLike.isFunctionPattern . Substitution.assignedTerm) $
            Substitution.unwrap substitution =
            return ()
        | otherwise =
            Left . show . Pretty.vsep $
                [ "Expected function-like unification solution, but found:"
                , Pretty.indent 4 (unparse conditional)
                ]
      where
        conditional =
            TermLike.mkTop (TermLike.termLikeSort left)
                `Pattern.withCondition` Condition.fromSubstitution substitution
        left = matchingPattern term

{- | Apply the initial conditions to the results of rule unification.

The rule is considered to apply if the result is not @\\bottom@.

@applyInitialConditions@ assumes that the unification solution includes the
@requires@ clause, and that their conjunction has already been simplified with
respect to the initial condition.
-}
applyInitialConditions ::
    -- | SideCondition containing metadata
    SideCondition RewritingVariableName ->
    -- | Initial conditions
    Condition RewritingVariableName ->
    -- | Unification conditions
    Condition RewritingVariableName ->
    LogicT Simplifier (Condition RewritingVariableName)
applyInitialConditions sideCondition initial unification = inContext "apply-initial-condition" $ do
    -- Combine the initial conditions and the unification conditions. The axiom
    -- requires clause is already included in the unification conditions, and
    -- the conjunction has already been simplified with respect to the initial
    -- conditions.
    applied <-
        -- Add the simplified unification solution to the initial conditions. We
        -- must preserve the initial conditions here, so it cannot be used as
        -- the side condition!
        Simplifier.simplifyCondition sideCondition (initial <> unification)
            & MultiOr.gather
    evaluated <- liftSimplifier $ SMT.Evaluator.filterMultiOr $srcLoc applied
    -- If 'evaluated' is \bottom, the rule is considered to not apply and
    -- no result is returned. If the result is \bottom after this check,
    -- then the rule is considered to apply with a \bottom result.
    Logic.scatter evaluated

{- | Simplify the remainder condition in the context of the side condition and the initial condition

This function assumes that the remainder is a pure boolean predicate, i.e. no configuration pieces/ceils etc. are involved. The simplifier should not branch on such pure predicates. This function will call @error@ if the simplifier returns more then one result.
-}
simplifyRemainder ::
    -- | SideCondition containing metadata
    SideCondition RewritingVariableName ->
    -- | Initial conditions
    Condition RewritingVariableName ->
    -- | Remainder condition
    Condition RewritingVariableName ->
    Simplifier (Condition RewritingVariableName)
simplifyRemainder sideCondition initialCondition remainderCondition = inContext "simplify-remainder" $ do
    let sideConditionWithInitialCondition =
            sideCondition
                & SideCondition.addConditionWithReplacements
                    initialCondition

    -- Simplify the remainder predicate under the side condition and the initial conditions.
    -- We must ensure that functions in the remainder are evaluated using the top-level
    -- side conditions because we will not re-evaluate them after they are added
    -- to the top level.
    simplifiedRemainderRaw <-
        Simplifier.simplifyCondition
            sideConditionWithInitialCondition
            remainderCondition
            & Logic.observeAllT

    -- convert to predicate from the list of conditionals produce by the simplifier
    -- TODO must gracefully handle the ?impossible? case of more then one simplifier branch
    let simplifiedRemainder = case simplifiedRemainderRaw of
            [singleResult] -> singleResult
            _ -> error "more then one result after simplifying the remainder condition"

    pure simplifiedRemainder

-- | Apply the remainder predicate to the given initial configuration.
applyRemainder ::
    -- | SideCondition containing metadata
    SideCondition RewritingVariableName ->
    -- | Initial configuration
    Pattern RewritingVariableName ->
    -- | Remainder
    Condition RewritingVariableName ->
    LogicT Simplifier (Pattern RewritingVariableName)
applyRemainder sideCondition initial remainder = inContext "apply-remainder" $ do
    -- Add the remainder to the initial conditions.
    Simplifier.simplifyCondition
        sideCondition
        (Pattern.andCondition initial remainder)
        <&> Pattern.mapVariables resetConfigVariable

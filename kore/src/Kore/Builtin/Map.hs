{- |
Module      : Kore.Builtin.Map
Description : Built-in key-value maps
Copyright   : (c) Runtime Verification, 2018
License     : NCSA
Maintainer  : thomas.tuegel@runtimeverification.com

This module is intended to be imported qualified, to avoid collision with other
builtin modules.

@
    import qualified Kore.Builtin.Map as Map
@
 -}

{-# LANGUAGE Strict #-}

module Kore.Builtin.Map
    ( sort
    , verifiers
    , builtinFunctions
    , Map.asTermLike
    , internalize
    , InKeys (..)
    , matchInKeys
    , matchUnifyNotInKeys
    , matchUnifyEqualsMap
    -- * Unification
    , unifyEquals
    , unifyNotInKeys
    -- * Raw evaluators
    , evalConcat
    , evalElement
    , evalUnit
    , evalInKeys
    ) where

import Prelude.Kore

import Control.Error
    ( MaybeT
    , hoistMaybe
    )
import qualified Control.Monad as Monad
import qualified Data.HashMap.Strict as HashMap
import qualified Data.List as List
import Data.Map.Strict
    ( Map
    )
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import Data.Text
    ( Text
    )

import Kore.Attribute.Hook
    ( Hook (..)
    )
import qualified Kore.Attribute.Symbol as Attribute
import qualified Kore.Builtin.AssociativeCommutative as Ac
import Kore.Builtin.Attributes
    ( isConstructorModulo_
    )
import qualified Kore.Builtin.Bool as Bool
import Kore.Builtin.Builtin
    ( acceptAnySort
    )
import qualified Kore.Builtin.Builtin as Builtin
import qualified Kore.Builtin.Int as Int
import qualified Kore.Builtin.List as Builtin.List
import qualified Kore.Builtin.Map.Map as Map
import qualified Kore.Builtin.Set as Builtin.Set
import Kore.IndexedModule.MetadataTools
    ( SmtMetadataTools
    )
import qualified Kore.Internal.Condition as Condition
import Kore.Internal.InternalMap
import Kore.Internal.InternalSet
    ( Value (SetValue)
    )
import qualified Kore.Internal.OrPattern as OrPattern
import Kore.Internal.Pattern
    ( Condition
    , Pattern
    )
import qualified Kore.Internal.Pattern as Pattern
import Kore.Internal.Predicate
    ( makeCeilPredicate
    )
import qualified Kore.Internal.SideCondition as SideCondition
import Kore.Internal.Symbol
    ( Symbol (..)
    , symbolHook
    )
import Kore.Internal.TermLike
    ( pattern App_
    , pattern InternalMap_
    , Key
    , TermLike
    , retractKey
    , termLikeSort
    )
import qualified Kore.Internal.TermLike as TermLike
import Kore.Rewriting.RewritingVariable
    ( RewritingVariableName
    )
import Kore.Sort
    ( Sort
    )
import Kore.Step.Simplification.NotSimplifier
import Kore.Step.Simplification.Simplify as Simplifier
import Kore.Syntax.Sentence
    ( SentenceSort (..)
    )
import Kore.Unification.Unify
    ( MonadUnify
    , explainAndReturnBottom
    )
import qualified Kore.Unification.Unify as Unify

{- | Builtin name of the @Map@ sort.
 -}
sort :: Text
sort = "MAP.Map"

{- | Is the given sort hooked to the builtin Map sort?

Returns Nothing if the sort is unknown (i.e. the _PREDICATE sort).
Returns Just False if the sort is a variable.
-}
isMapSort :: SmtMetadataTools attrs -> Sort -> Maybe Bool
isMapSort = Builtin.isSort sort

{- | Verify that the sort is hooked to the builtin @Int@ sort.

  See also: 'sort', 'Builtin.verifySort'

 -}
assertSort :: Builtin.SortVerifier
assertSort = Builtin.verifySort sort

verifiers :: Builtin.Verifiers
verifiers =
    Builtin.Verifiers
        { sortDeclVerifiers
        , symbolVerifiers
        , patternVerifierHook = mempty
        }

{- | Verify that hooked sort declarations are well-formed.

  See also: 'Builtin.verifySortDecl'

 -}
sortDeclVerifiers :: Builtin.SortDeclVerifiers
sortDeclVerifiers =
    HashMap.fromList [ (sort, verifySortDecl) ]
  where
    verifySortDecl indexedModule sentenceSort attrs = do
        Builtin.verifySortDecl indexedModule sentenceSort attrs
        unitId <- Builtin.getUnitId attrs
        Builtin.assertSymbolHook indexedModule unitId Map.unitKey
        Builtin.assertSymbolResultSort indexedModule unitId expectedSort
        elementId <- Builtin.getElementId attrs
        Builtin.assertSymbolHook indexedModule elementId Map.elementKey
        Builtin.assertSymbolResultSort indexedModule elementId expectedSort
        concatId <- Builtin.getConcatId attrs
        Builtin.assertSymbolHook indexedModule concatId Map.concatKey
        Builtin.assertSymbolResultSort indexedModule concatId expectedSort
        return ()
      where
        SentenceSort { sentenceSortName } = sentenceSort
        expectedSort = TermLike.mkSort sentenceSortName

{- | Verify that hooked symbol declarations are well-formed.

  See also: 'Builtin.verifySymbol'

 -}
symbolVerifiers :: Builtin.SymbolVerifiers
symbolVerifiers =
    HashMap.fromList
    [ ( Map.concatKey
      , Builtin.verifySymbol assertSort [assertSort , assertSort]
      )
    , ( Map.elementKey
      , Builtin.verifySymbol assertSort [acceptAnySort, acceptAnySort]
      )
    , ( Map.lookupKey
      , Builtin.verifySymbol acceptAnySort [assertSort, acceptAnySort]
      )
    , ( Map.lookupOrDefaultKey
      , Builtin.verifySymbol acceptAnySort
            [assertSort, acceptAnySort, acceptAnySort]
      )
    , ( Map.unitKey
      , Builtin.verifySymbol assertSort []
      )
    , ( Map.updateKey
      , Builtin.verifySymbol assertSort
            [assertSort, acceptAnySort, acceptAnySort]
      )
    , ( Map.in_keysKey
      , Builtin.verifySymbol Bool.assertSort [acceptAnySort, assertSort]
      )
    , ( Map.keysKey
      , Builtin.verifySymbol Builtin.Set.assertSort [assertSort]
      )
    , ( Map.keys_listKey
      , Builtin.verifySymbol Builtin.List.assertSort [assertSort]
      )
    , ( Map.removeKey
      , Builtin.verifySymbol assertSort [assertSort, acceptAnySort]
      )
    , ( Map.removeAllKey
      , Builtin.verifySymbol assertSort [assertSort, Builtin.Set.assertSort]
      )
    , ( Map.sizeKey
      , Builtin.verifySymbol Int.assertSort [assertSort]
      )
    , ( Map.valuesKey
      , Builtin.verifySymbol Builtin.List.assertSort [assertSort]
      )
    , ( Map.inclusionKey
      , Builtin.verifySymbol Bool.assertSort [assertSort, assertSort]
      )
    ]

{- | Abort function evaluation if the argument is not a Map domain value.

    If the operand pattern is not a domain value, the function is simply
    'NotApplicable'. If the operand is a domain value, but not represented
    by a 'BuiltinDomainMap', it is a bug.

 -}
expectBuiltinMap
    :: Monad m
    => Text  -- ^ Context for error message
    -> TermLike variable  -- ^ Operand pattern
    -> MaybeT m (Ac.TermNormalizedAc NormalizedMap variable)
expectBuiltinMap _ (InternalMap_ internalMap) = do
    let InternalAc { builtinAcChild } = internalMap
    return builtinAcChild
expectBuiltinMap _ _ = empty

{- | Returns @empty@ if the argument is not a @NormalizedMap@ domain value
which consists only of concrete elements.

Returns the @Map@ of concrete elements otherwise.
-}
expectConcreteBuiltinMap
    :: MonadSimplify m
    => Text  -- ^ Context for error message
    -> TermLike variable  -- ^ Operand pattern
    -> MaybeT m (Map Key (MapValue (TermLike variable)))
expectConcreteBuiltinMap ctx _map = do
    _map <- expectBuiltinMap ctx _map
    case unwrapAc _map of
        NormalizedAc
            { elementsWithVariables = []
            , concreteElements
            , opaque = []
            } -> return concreteElements
        _ -> empty

{- | Converts a @Map@ of concrete elements to a @NormalizedMap@ and returns it
as a function result.
-}
returnConcreteMap
    :: (MonadSimplify m, InternalVariable variable)
    => Sort
    -> Map Key (MapValue (TermLike variable))
    -> m (Pattern variable)
returnConcreteMap = Ac.returnConcreteAc

evalLookup :: Builtin.Function
evalLookup resultSort [_map, _key] = do
    let emptyMap = do
            _map <- expectConcreteBuiltinMap Map.lookupKey _map
            if Map.null _map
                then return (Pattern.bottomOf resultSort)
                else empty
        bothConcrete = do
            _key <- hoistMaybe $ retractKey _key
            _map <- expectConcreteBuiltinMap Map.lookupKey _map
            (return . maybeBottom)
                (getMapValue <$> Map.lookup _key _map)
    emptyMap <|> bothConcrete
    where
    maybeBottom = maybe (Pattern.bottomOf resultSort) Pattern.fromTermLike
evalLookup _ _ = Builtin.wrongArity Map.lookupKey

evalLookupOrDefault :: Builtin.Function
evalLookupOrDefault _ [_map, _key, _def] = do
    _key <- hoistMaybe $ retractKey _key
    _map <- expectConcreteBuiltinMap Map.lookupKey _map
    Map.lookup _key _map
        & maybe _def getMapValue
        & Pattern.fromTermLike
        & return
evalLookupOrDefault _ _ = Builtin.wrongArity Map.lookupOrDefaultKey

-- | evaluates the map element builtin.
evalElement :: Builtin.Function
evalElement resultSort [_key, _value] =
    case retractKey _key of
        Just concrete ->
            Map.singleton concrete (MapValue _value)
            & returnConcreteMap resultSort
            & TermLike.assertConstructorLikeKeys [_key]
        Nothing ->
            (Ac.returnAc resultSort . wrapAc)
            NormalizedAc
                { elementsWithVariables =
                    [MapElement (_key, _value)]
                , concreteElements = Map.empty
                , opaque = []
                }
evalElement _ _ = Builtin.wrongArity Map.elementKey

-- | evaluates the map concat builtin.
evalConcat :: Builtin.Function
evalConcat resultSort [map1, map2] =
    Ac.evalConcatNormalizedOrBottom @NormalizedMap
        resultSort
        (Ac.toNormalized map1)
        (Ac.toNormalized map2)
evalConcat _ _ = Builtin.wrongArity Map.concatKey

evalUnit :: Builtin.Function
evalUnit resultSort =
    \case
        [] -> returnConcreteMap resultSort Map.empty
        _ -> Builtin.wrongArity Map.unitKey

evalUpdate :: Builtin.Function
evalUpdate resultSort [_map, _key, value] = do
    _key <- hoistMaybe $ retractKey _key
    _map <- expectConcreteBuiltinMap Map.updateKey _map
    Map.insert _key (MapValue value) _map
        & returnConcreteMap resultSort
evalUpdate _ _ = Builtin.wrongArity Map.updateKey

evalInKeys :: Builtin.Function
evalInKeys resultSort arguments@[_key, _map] =
    emptyMap <|> concreteMap <|> symbolicMap
  where
    mkCeilUnlessDefined termLike
      | TermLike.isDefinedPattern termLike = Condition.top
      | otherwise =
        Condition.fromPredicate (makeCeilPredicate termLike)

    returnPattern = return . flip Pattern.andCondition conditions
    conditions = foldMap mkCeilUnlessDefined arguments

    -- The empty map contains no keys.
    emptyMap = do
        _map <- expectConcreteBuiltinMap Map.in_keysKey _map
        Monad.guard (Map.null _map)
        Bool.asPattern resultSort False & returnPattern

    -- When the map is concrete, decide if a concrete key is present or absent.
    concreteMap = do
        _map <- expectConcreteBuiltinMap Map.in_keysKey _map
        _key <- hoistMaybe $ retractKey _key
        Map.member _key _map
            & Bool.asPattern resultSort
            & returnPattern

    -- When the map is symbolic, decide if a key is present.
    symbolicMap = do
        _map <- expectBuiltinMap Map.in_keysKey _map
        let inKeys =
                (or . catMaybes)
                -- The key may be concrete or symbolic.
                [ do
                    _key <- retractKey _key
                    pure (isConcreteKeyOfAc _key _map)
                , pure (isSymbolicKeyOfAc _key _map)
                ]
        Monad.guard inKeys
        -- We cannot decide if the key is absent because the Map is symbolic.
        Bool.asPattern resultSort True & returnPattern

evalInKeys _ _ = Builtin.wrongArity Map.in_keysKey

evalInclusion :: Builtin.Function
evalInclusion resultSort [_mapLeft, _mapRight] = do
    _mapLeft <- expectConcreteBuiltinMap Map.inclusionKey _mapLeft
    _mapRight <- expectConcreteBuiltinMap Map.inclusionKey _mapRight
    Map.isSubmapOf _mapLeft _mapRight
        & Bool.asPattern resultSort
        & return
evalInclusion _ _ = Builtin.wrongArity Map.inclusionKey

evalKeys :: Builtin.Function
evalKeys resultSort [_map] = do
    _map <- expectConcreteBuiltinMap Map.keysKey _map
    fmap (const SetValue) _map
        & Builtin.Set.returnConcreteSet resultSort
evalKeys _ _ = Builtin.wrongArity Map.keysKey

evalKeysList :: Builtin.Function
evalKeysList resultSort [_map] = do
    _map <- expectConcreteBuiltinMap Map.keys_listKey _map
    Map.keys _map
        & fmap (from @Key)
        & Seq.fromList
        & Builtin.List.returnList resultSort
evalKeysList _ _ = Builtin.wrongArity Map.keys_listKey

evalRemove :: Builtin.Function
evalRemove resultSort [_map, _key] = do
    let emptyMap = do
            _map <- expectConcreteBuiltinMap Map.removeKey _map
            if Map.null _map
                then returnConcreteMap resultSort Map.empty
                else empty
        bothConcrete = do
            _map <- expectConcreteBuiltinMap Map.removeKey _map
            _key <- hoistMaybe $ retractKey _key
            returnConcreteMap resultSort $ Map.delete _key _map
    emptyMap <|> bothConcrete
evalRemove _ _ = Builtin.wrongArity Map.removeKey

evalRemoveAll :: Builtin.Function
evalRemoveAll resultSort [_map, _set] = do
    let emptyMap = do
            _map <- expectConcreteBuiltinMap Map.removeAllKey _map
            if Map.null _map
                then returnConcreteMap resultSort Map.empty
                else empty
        bothConcrete = do
            _map <- expectConcreteBuiltinMap Map.removeAllKey _map
            _set <-
                Builtin.Set.expectConcreteBuiltinSet
                    Map.removeAllKey
                    _set
            Map.difference _map _set
                & returnConcreteMap resultSort
    emptyMap <|> bothConcrete
evalRemoveAll _ _ = Builtin.wrongArity Map.removeAllKey

evalSize :: Builtin.Function
evalSize resultSort [_map] = do
    _map <- expectConcreteBuiltinMap Map.sizeKey _map
    Map.size _map
        & toInteger
        & Int.asPattern resultSort
        & return
evalSize _ _ = Builtin.wrongArity Map.sizeKey

evalValues :: Builtin.Function
evalValues resultSort [_map] = do
    _map <- expectConcreteBuiltinMap Map.valuesKey _map
    fmap getMapValue (Map.elems _map)
        & Seq.fromList
        & Builtin.List.returnList resultSort
evalValues _ _ = Builtin.wrongArity Map.valuesKey

{- | Implement builtin function evaluation.
 -}
builtinFunctions :: Map Text BuiltinAndAxiomSimplifier
builtinFunctions =
    Map.fromList
        [ (Map.concatKey, Builtin.functionEvaluator evalConcat)
        , (Map.lookupKey, Builtin.functionEvaluator evalLookup)
        , (Map.lookupOrDefaultKey, Builtin.functionEvaluator evalLookupOrDefault)
        , (Map.elementKey, Builtin.functionEvaluator evalElement)
        , (Map.unitKey, Builtin.functionEvaluator evalUnit)
        , (Map.updateKey, Builtin.functionEvaluator evalUpdate)
        , (Map.in_keysKey, Builtin.functionEvaluator evalInKeys)
        , (Map.keysKey, Builtin.functionEvaluator evalKeys)
        , (Map.keys_listKey, Builtin.functionEvaluator evalKeysList)
        , (Map.removeKey, Builtin.functionEvaluator evalRemove)
        , (Map.removeAllKey, Builtin.functionEvaluator evalRemoveAll)
        , (Map.sizeKey, Builtin.functionEvaluator evalSize)
        , (Map.valuesKey, Builtin.functionEvaluator evalValues)
        , (Map.inclusionKey, Builtin.functionEvaluator evalInclusion)
        ]

{- | Convert a Map-sorted 'TermLike' to its internal representation.

The 'TermLike' is unmodified if it is not Map-sorted. @internalize@ only
operates at the top-most level, it does not descend into the 'TermLike' to
internalize subterms.

 -}
internalize
    :: InternalVariable variable
    => SmtMetadataTools Attribute.Symbol
    -> TermLike variable
    -> TermLike variable
internalize tools termLike
  | fromMaybe False (isMapSort tools sort')
  -- Ac.toNormalized is greedy about 'normalizing' opaque terms, we should only
  -- apply it if we know the term head is a constructor-like symbol.
  , App_ symbol _ <- termLike
  , isConstructorModulo_ symbol =
    case Ac.toNormalized @NormalizedMap termLike of
        Ac.Bottom                    -> TermLike.mkBottom sort'
        Ac.Normalized termNormalized
          | let unwrapped = unwrapAc termNormalized
          , null (elementsWithVariables unwrapped)
          , null (concreteElements unwrapped)
          , [singleOpaqueTerm] <- opaque unwrapped
          ->
            -- When the 'normalized' term consists of a single opaque Map-sorted
            -- term, we should prefer to return only that term.
            singleOpaqueTerm
          | otherwise -> Ac.asInternal tools sort' termNormalized
  | otherwise = termLike
  where
    sort' = termLikeSort termLike

data UnifyMapEqualsArgs = UnifyMapEqualsArgs {
    preElts1, preElts2 :: [Element NormalizedMap (TermLike RewritingVariableName)]
    , concreteElts1, concreteElts2 :: Map.Map Key (Value NormalizedMap (TermLike RewritingVariableName))
    , opaque1, opaque2 :: [TermLike RewritingVariableName]
}

data UnifyMapEqualsVarArgs = UnifyMapEqualsVarArgs {
    preElts1, preElts2 :: [Element NormalizedMap (TermLike RewritingVariableName)]
    , concreteElts1, concreteElts2 :: Map.Map Key (Value NormalizedMap (TermLike RewritingVariableName))
    , opaque1, opaque2 :: [TermLike RewritingVariableName]
    , var :: TermLike.ElementVariable RewritingVariableName
}

data UnifyEqualsMap
    = UnifyEqualsMap1 !UnifyMapEqualsArgs
    | UnifyEqualsMap2 !UnifyMapEqualsVarArgs
    | UnifyEqualsMap3 !UnifyMapEqualsVarArgs
    | UnifyMapBottom

unifyMapEqualsMatch ::
    Ac.TermNormalizedAc NormalizedMap RewritingVariableName ->
    Ac.TermNormalizedAc NormalizedMap RewritingVariableName ->
    Maybe UnifyEqualsMap
unifyMapEqualsMatch
    norm1
    norm2 = case (opaqueDifference1, opaqueDifference2) of
        ([],[]) -> Just $ UnifyEqualsMap1 $ UnifyMapEqualsArgs preElementsWithVariables1 preElementsWithVariables2 concreteElements1 concreteElements2 opaque1 opaque2
        ([TermLike.ElemVar_ v1], _) -> Just $ UnifyEqualsMap2 $ UnifyMapEqualsVarArgs preElementsWithVariables1 preElementsWithVariables2 concreteElements1 concreteElements2 opaque1 opaque2 v1
        (_, [TermLike.ElemVar_ v2]) -> Just $ UnifyEqualsMap3 $ UnifyMapEqualsVarArgs preElementsWithVariables1 preElementsWithVariables2 concreteElements1 concreteElements2 opaque1 opaque2 v2
        _ -> Nothing

      where
        listToMap :: Ord a => [a] -> Map.Map a Int
        listToMap = List.foldl' (\m k -> Map.insertWith (+) k 1 m) Map.empty
        mapToList :: Map.Map a Int -> [a]
        mapToList =
            Map.foldrWithKey
                (\key count' result -> List.replicate count' key ++ result)
                []

        NormalizedAc
            { elementsWithVariables = preElementsWithVariables1
            , concreteElements = concreteElements1
            , opaque = opaque1
            } =
                unwrapAc norm1
        NormalizedAc
            { elementsWithVariables = preElementsWithVariables2
            , concreteElements = concreteElements2
            , opaque = opaque2
            } =
                unwrapAc norm2

        --opaque1Map :: M.Map (TermLike RewritingVariableName) Int
        opaque1Map = listToMap opaque1
        opaque2Map = listToMap opaque2

        -- Duplicates must be kept in case any of the opaque terms turns out to be
        -- non-empty, in which case one of the terms is bottom, which
        -- means that the unification result is bottom.
        commonOpaqueMap = Map.intersectionWith max opaque1Map opaque2Map

        commonOpaqueKeys = Map.keysSet commonOpaqueMap

        opaqueDifference1 =
            mapToList (Map.withoutKeys opaque1Map commonOpaqueKeys)
        opaqueDifference2 =
            mapToList (Map.withoutKeys opaque2Map commonOpaqueKeys)

matchUnifyEqualsMap
    :: SmtMetadataTools Attribute.Symbol
    -> TermLike RewritingVariableName
    -> TermLike RewritingVariableName
    -> Maybe UnifyEqualsMap
matchUnifyEqualsMap tools first second
    | Just True <- isMapSort tools sort1
    = case unifyEquals0 first second of
        Just (norm1, norm2) ->
            let InternalAc{builtinAcChild = firstNormalized} =
                    norm1 in
            let InternalAc{builtinAcChild = secondNormalized} =
                    norm2 in
            unifyMapEqualsMatch firstNormalized secondNormalized
        Nothing -> return UnifyMapBottom
    | otherwise = Nothing

      where

        unifyEquals0 (InternalMap_ normalized1) (InternalMap_ normalized2)
          = return (normalized1, normalized2)
        unifyEquals0 first' second'
          = do
              firstDomain <- asDomain first'
              secondDomain <- asDomain second'
              unifyEquals0 firstDomain secondDomain

        sort1 = termLikeSort first

        asDomain ::
            TermLike RewritingVariableName ->
            Maybe (TermLike RewritingVariableName)
        asDomain patt =
            case normalizedOrBottom of
                Ac.Normalized normalized -> Just $
                    --tools <- Simplifier.askMetadataTools
                    Ac.asInternal tools sort1 normalized
                Ac.Bottom -> Nothing

          where
            normalizedOrBottom ::
                Ac.NormalizedOrBottom NormalizedMap RewritingVariableName
            normalizedOrBottom = Ac.toNormalized patt


{- | Simplify the conjunction or equality of two concrete Map domain values.

When it is used for simplifying equality, one should separately solve the
case ⊥ = ⊥. One should also throw away the term in the returned pattern.

The maps are assumed to have the same sort, but this is not checked. If
multiple sorts are hooked to the same builtin domain, the verifier should
reject the definition.
-}

unifyEquals
    :: forall unifier
    .  MonadUnify unifier
    => SmtMetadataTools Attribute.Symbol
    -> ( TermLike RewritingVariableName ->
         TermLike RewritingVariableName ->
         unifier (Pattern RewritingVariableName)
       )
    -> TermLike RewritingVariableName
    -> TermLike RewritingVariableName
    -> UnifyEqualsMap
    -> MaybeT unifier (Pattern RewritingVariableName)
unifyEquals tools childTransformers first second unifyData
    = case unifyData of
        UnifyEqualsMap1 unifyData' ->
            Ac.unifyEqualsNormalized tools first second $
                Ac.unifyEqualsNormalizedAc
                    first
                    second
                    childTransformers
                    preElts1
                    preElts2
                    concreteElts1
                    concreteElts2
                    opaque1
                    opaque2 $ lift $
                        Ac.unifyEqualsElementLists
                            tools
                            first
                            second
                            childTransformers
                            (Ac.allElements1 preElts1 preElts2 concreteElts1 concreteElts2)
                            (Ac.allElements2 preElts1 preElts2 concreteElts1 concreteElts2)
                            Nothing
          where
            UnifyMapEqualsArgs { preElts1, preElts2, concreteElts1, concreteElts2, opaque1, opaque2 } = unifyData'
        UnifyEqualsMap2 unifyData' ->
            Ac.unifyEqualsNormalized tools first second $
                Ac.unifyEqualsNormalizedAc
                    first
                    second
                    childTransformers
                    preElts1
                    preElts2
                    concreteElts1
                    concreteElts2
                    opaque1
                    opaque2 $
                        if null $ Ac.opaqueDifference2 opaque1 opaque2 then
                            lift $ Ac.unifyEqualsElementLists
                                tools
                                first
                                second
                                childTransformers
                                (Ac.allElements1 preElts1 preElts2 concreteElts1 concreteElts2)
                                (Ac.allElements2 preElts1 preElts2 concreteElts1 concreteElts2)
                                (Just var)
                        else if null $ Ac.allElements1 preElts1 preElts2 concreteElts1 concreteElts2 then
                            Ac.unifyOpaqueVariable
                                tools
                                undefined
                                childTransformers
                                var
                                (Ac.allElements2 preElts1 preElts2 concreteElts1 concreteElts2)
                                (Ac.opaqueDifference2 opaque1 opaque2)
                        else empty
          where
            UnifyMapEqualsVarArgs { preElts1, preElts2, concreteElts1, concreteElts2, opaque1, opaque2, var } = unifyData'
        UnifyEqualsMap3 unifyData' ->
            Ac.unifyEqualsNormalized tools first second $
                    Ac.unifyEqualsNormalizedAc
                        first
                        second
                        childTransformers
                        preElts1
                        preElts2
                        concreteElts1
                        concreteElts2
                        opaque1
                        opaque2 $
                            if null $ Ac.opaqueDifference1 opaque1 opaque2 then
                                lift $ Ac.unifyEqualsElementLists
                                    tools
                                    first
                                    second
                                    childTransformers
                                    (Ac.allElements2 preElts1 preElts2 concreteElts1 concreteElts2)
                                    (Ac.allElements1 preElts1 preElts2 concreteElts1 concreteElts2)
                                    (Just var)
                            else if null $ Ac.allElements2 preElts1 preElts2 concreteElts1 concreteElts2 then
                                Ac.unifyOpaqueVariable
                                    tools
                                    undefined
                                    childTransformers
                                    var
                                    (Ac.allElements1 preElts1 preElts2 concreteElts1 concreteElts2)
                                    (Ac.opaqueDifference1 opaque1 opaque2)
                            else empty
          where
            UnifyMapEqualsVarArgs { preElts1, preElts2, concreteElts1, concreteElts2, opaque1, opaque2, var } = unifyData'
        UnifyMapBottom ->
            lift $ explainAndReturnBottom
            "Duplicated elements in normalization." first second

-- data UnifyEqualsMap
--     = UnifyEqualsMap1 !UnifyMapEqualsArgs
--     | UnifyEqualsMap2 !UnifyMapEqualsVarArgs
--     | UnifyEqualsMap3 !UnifyMapEqualsVarArgs
--     | UnifyMapBottom

-- unifyEquals1
--     :: forall unifier
--     .  MonadUnify unifier
--     => SmtMetadataTools Attribute.Symbol
--     -> TermLike RewritingVariableName
--     -> TermLike RewritingVariableName
--     -> ( TermLike RewritingVariableName ->
--          TermLike RewritingVariableName ->
--          unifier (Pattern RewritingVariableName)
--        )
--     -> [Element NormalizedMap (TermLike RewritingVariableName)]
--     -> [Element NormalizedMap (TermLike RewritingVariableName)]
--     -> Map Key (Value NormalizedMap (TermLike RewritingVariableName))
--     -> Map Key (Value NormalizedMap (TermLike RewritingVariableName))
--     -> [TermLike RewritingVariableName]
--     -> [TermLike RewritingVariableName]
--     -> MaybeT unifier (Pattern RewritingVariableName)
-- unifyEquals1 tools first second childTransformers preElt1 preElt2 concreteElt1 concreteElt2 opaque1 opaque2 =
--     Ac.unifyEqualsNormalized tools first second $
--             Ac.unifyEqualsNormalizedAc
--                 first
--                 second
--                 childTransformers
--                 preElt1
--                 preElt2
--                 concreteElt1
--                 concreteElt2
--                 opaque1
--                 opaque2 $ lift $
--                     Ac.unifyEqualsElementLists
--                         tools
--                         first
--                         second
--                         childTransformers
--                         (Ac.allElements1 preElt1 preElt2 concreteElt1 concreteElt2)
--                         (Ac.allElements2 preElt1 preElt2 concreteElt1 concreteElt2)
--                         Nothing

-- unifyEquals2
--     :: forall unifier
--     .  MonadUnify unifier
--     => SmtMetadataTools Attribute.Symbol
--     -> TermLike RewritingVariableName
--     -> TermLike RewritingVariableName
--     -> ( TermLike RewritingVariableName ->
--          TermLike RewritingVariableName ->
--          unifier (Pattern RewritingVariableName)
--        )
--     -> [Element NormalizedMap (TermLike RewritingVariableName)]
--     -> [Element NormalizedMap (TermLike RewritingVariableName)]
--     -> Map Key (Value NormalizedMap (TermLike RewritingVariableName))
--     -> Map Key (Value NormalizedMap (TermLike RewritingVariableName))
--     -> [TermLike RewritingVariableName]
--     -> [TermLike RewritingVariableName]
--     -> TermLike.ElementVariable RewritingVariableName
--     -> MaybeT unifier (Pattern RewritingVariableName)
-- unifyEquals2 tools first second childTransformers preElt1 preElt2 concreteElt1 concreteElt2 opaque1 opaque2 var =
--     Ac.unifyEqualsNormalized tools first second $
--             Ac.unifyEqualsNormalizedAc
--                 first
--                 second
--                 childTransformers
--                 preElt1
--                 preElt2
--                 concreteElt1
--                 concreteElt2
--                 opaque1
--                 opaque2 $
--                     if null $ Ac.opaqueDifference2 opaque1 opaque2 then
--                         lift $ Ac.unifyEqualsElementLists
--                             tools
--                             first
--                             second
--                             childTransformers
--                             (Ac.allElements1 preElt1 preElt2 concreteElt1 concreteElt2)
--                             (Ac.allElements2 preElt1 preElt2 concreteElt1 concreteElt2)
--                             (Just var)
--                     else if null $ Ac.allElements1 preElt1 preElt2 concreteElt1 concreteElt2 then
--                         Ac.unifyOpaqueVariable
--                             tools
--                             undefined
--                             childTransformers
--                             var
--                             (Ac.allElements2 preElt1 preElt2 concreteElt1 concreteElt2)
--                             (Ac.opaqueDifference2 opaque1 opaque2)
--                     else empty

-- unifyEquals3
--     :: forall unifier
--     .  MonadUnify unifier
--     => SmtMetadataTools Attribute.Symbol
--     -> TermLike RewritingVariableName
--     -> TermLike RewritingVariableName
--     -> ( TermLike RewritingVariableName ->
--          TermLike RewritingVariableName ->
--          unifier (Pattern RewritingVariableName)
--        )
--     -> [Element NormalizedMap (TermLike RewritingVariableName)]
--     -> [Element NormalizedMap (TermLike RewritingVariableName)]
--     -> Map Key (Value NormalizedMap (TermLike RewritingVariableName))
--     -> Map Key (Value NormalizedMap (TermLike RewritingVariableName))
--     -> [TermLike RewritingVariableName]
--     -> [TermLike RewritingVariableName]
--     -> TermLike.ElementVariable RewritingVariableName
--     -> MaybeT unifier (Pattern RewritingVariableName)
-- unifyEquals3 tools first second childTransformers preElt1 preElt2 concreteElt1 concreteElt2 opaque1 opaque2 var =
--     Ac.unifyEqualsNormalized tools first second $
--             Ac.unifyEqualsNormalizedAc
--                 first
--                 second
--                 childTransformers
--                 preElt1
--                 preElt2
--                 concreteElt1
--                 concreteElt2
--                 opaque1
--                 opaque2 $
--                     if null $ Ac.opaqueDifference1 opaque1 opaque2 then
--                         lift $ Ac.unifyEqualsElementLists
--                             tools
--                             first
--                             second
--                             childTransformers
--                             (Ac.allElements2 preElt1 preElt2 concreteElt1 concreteElt2)
--                             (Ac.allElements1 preElt1 preElt2 concreteElt1 concreteElt2)
--                             (Just var)
--                     else if null $ Ac.allElements2 preElt1 preElt2 concreteElt1 concreteElt2 then
--                         Ac.unifyOpaqueVariable
--                             tools
--                             undefined
--                             childTransformers
--                             var
--                             (Ac.allElements1 preElt1 preElt2 concreteElt1 concreteElt2)
--                             (Ac.opaqueDifference1 opaque1 opaque2)
--                     else empty

data InKeys term =
    InKeys
        { symbol :: !Symbol
        , keyTerm, mapTerm :: !term
        }

instance
    InternalVariable variable
    => Injection (TermLike variable) (InKeys (TermLike variable))
  where
    inject InKeys { symbol, keyTerm, mapTerm } =
        TermLike.mkApplySymbol symbol [keyTerm, mapTerm]

    retract (App_ symbol [keyTerm, mapTerm]) = do
        hook2 <- (getHook . symbolHook) symbol
        Monad.guard (hook2 == Map.in_keysKey)
        return InKeys { symbol, keyTerm, mapTerm }
    retract _ = empty

matchInKeys
    :: InternalVariable variable
    => TermLike variable
    -> Maybe (InKeys (TermLike variable))
matchInKeys = retract

data UnifyNotInKeys = UnifyNotInKeys {
    inKeys :: !(InKeys (TermLike RewritingVariableName))
    , keyTerm, mapTerm :: !(TermLike RewritingVariableName)
}

matchUnifyNotInKeys
    :: TermLike RewritingVariableName
    -> Maybe UnifyNotInKeys
matchUnifyNotInKeys first
    | Just boolValue <- Bool.matchBool first
    , not boolValue
    , Just inKeys@InKeys { keyTerm, mapTerm } <- matchInKeys first
    = Just $ UnifyNotInKeys inKeys keyTerm mapTerm
    | otherwise = Nothing

unifyNotInKeys
    :: forall unifier
    .  MonadUnify unifier
    => TermSimplifier RewritingVariableName unifier
    -> NotSimplifier unifier
    -> TermLike RewritingVariableName
    -> UnifyNotInKeys
    -> MaybeT unifier (Pattern RewritingVariableName)
unifyNotInKeys unifyChildren (NotSimplifier notSimplifier) termLike1 unifyData =
    worker termLike1 inKeys keyTerm mapTerm
  where
    normalizedOrBottom
       :: InternalVariable variable
       => TermLike variable
       -> Ac.NormalizedOrBottom NormalizedMap variable
    normalizedOrBottom = Ac.toNormalized

    defineTerm
        :: TermLike RewritingVariableName
        -> MaybeT unifier (Condition RewritingVariableName)
    defineTerm termLike =
        makeEvaluateTermCeil SideCondition.topTODO termLike
        >>= Unify.scatter
        & lift

    eraseTerm =
        Pattern.fromCondition_ . Pattern.withoutTerm

    unifyAndNegate t1 t2 = do
        -- Erasing the unified term is valid here because
        -- the terms are all wrapped in \ceil below.
        unificationSolutions <-
            fmap eraseTerm
            <$> Unify.gather (unifyChildren t1 t2)
        notSimplifier
            SideCondition.top
            (OrPattern.fromPatterns unificationSolutions)
        >>= Unify.scatter

    collectConditions terms = fold terms & Pattern.fromCondition_

    UnifyNotInKeys { inKeys, keyTerm, mapTerm } = unifyData

    worker
        :: TermLike RewritingVariableName
       -- -> TermLike RewritingVariableName
        -> InKeys (TermLike RewritingVariableName)
        -> TermLike RewritingVariableName
        -> TermLike RewritingVariableName
        -> MaybeT unifier (Pattern RewritingVariableName)
    worker termLike inKeys' keyTerm' mapTerm'
      |  Ac.Normalized normalizedMap <- normalizedOrBottom mapTerm
      = do
        let symbolicKeys = getSymbolicKeysOfAc normalizedMap
            concreteKeys = from @Key <$> getConcreteKeysOfAc normalizedMap
            mapKeys = symbolicKeys <> concreteKeys
            opaqueElements = opaque . unwrapAc $ normalizedMap
        if null mapKeys && null opaqueElements then
            return Pattern.top
        else do
            Monad.guard (not (null mapKeys) || (length opaqueElements > 1))
            -- Concrete keys are constructor-like, therefore they are defined
            TermLike.assertConstructorLikeKeys concreteKeys $ return ()
            definedKey <- defineTerm keyTerm'
            definedMap <- defineTerm mapTerm'
            keyConditions <- lift $ traverse (unifyAndNegate keyTerm) mapKeys

            let keyInKeysOpaque =
                    (\term -> inject @(TermLike _) (inKeys' :: InKeys (TermLike RewritingVariableName)) { mapTerm = term })
                    <$> opaqueElements

            opaqueConditions <-
                lift $ traverse (unifyChildren termLike) keyInKeysOpaque
            let conditions =
                    fmap Pattern.withoutTerm (keyConditions <> opaqueConditions)
                    <> [definedKey, definedMap]
            return $ collectConditions conditions
      | otherwise = empty

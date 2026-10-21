------------------------------- MODULE Cascade -------------------------------
(***************************************************************************)
(* Ending an owner closes every open descendant in the same commit.        *)
(* Descendants close before their owners, and the session end is last.     *)
(***************************************************************************)
EXTENDS FiniteSets, Integers, Sequences

CONSTANT Entities

VARIABLES open, commit
vars == <<open, commit>>

Parent(entity) ==
    CASE entity = "call" -> "run"
      [] entity = "run" -> "turn"
      [] OTHER -> "session"

TypeOK ==
    /\ open \subseteq Entities
    /\ commit \in Seq(Entities \cup {"session"})

Init ==
    /\ open = Entities
    /\ commit = <<>>

RECURSIVE Below(_, _)
Below(entity, owner) ==
    IF Parent(entity) = owner THEN TRUE
    ELSE IF Parent(entity) = "session" THEN FALSE
    ELSE Below(Parent(entity), owner)

Depth(entity) == Cardinality({candidate \in Entities : Below(entity, candidate)})

Ordered(descendants) == SelectSeq(<<"call", "run", "turn">>, LAMBDA entity : entity \in descendants)

End(owner) ==
    LET descendants == {entity \in open : Below(entity, owner)} IN
    LET ordered == Ordered(descendants)
    IN
    /\ commit' = ordered \o <<owner>>
    /\ open' = (open \ descendants) \ {owner}

Next == \E owner \in open \cup {"session"} : End(owner)

OwnerClosesDescendants ==
    \A entity \in open : \A index \in 1..Len(commit) :
        commit[index] = Parent(entity) => entity \in {commit[before] : before \in 1..(index - 1)}

SessionEndLast ==
    "session" \in {commit[index] : index \in 1..Len(commit)} => commit[Len(commit)] = "session"

Spec == Init /\ [][Next]_vars
=============================================================================

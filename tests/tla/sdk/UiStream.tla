------------------------------ MODULE UiStream ------------------------------
(***************************************************************************)
(* A session's UI stream in a World, as a reader in another process sees   *)
(* it while workers write it. libfx numbers each line by its place in the  *)
(* stored stream, and `stream(cursor)` reads from that place, so a live    *)
(* reader must get exactly the lines, in the order and under the cursors,  *)
(* that a replay from cursor 0 gets (DUR-38).                              *)
(*                                                                         *)
(* A worker pushes lines in order and writes them as libfx's UI writer     *)
(* does: at once when no write is in flight, and the lines pushed          *)
(* meanwhile together in the next write. A batch written with one call     *)
(* becomes visible chunk by chunk, in any order when the World writes a    *)
(* batch's chunks in parallel, as world-local does, and in order when it   *)
(* keeps a batch's order, as Vercel's World does with one request. A       *)
(* reader in another process takes each chunk once it is visible, the      *)
(* lowest place first among those it has not had, as world-local's reader *)
(* does when it polls the stream's folder.                                 *)
(*                                                                         *)
(* OneByOne is the fix for one worker: libfx writes each line before the   *)
(* next unless the World keeps a batch's order. The witness                *)
(* UiStreamWitness-Batched writes batches to a World that does not, as     *)
(* libfx did, and breaks LiveIsReplay.                                     *)
(*                                                                         *)
(* With Takeover, the worker A can freeze while a write of its own is on   *)
(* its way to the World, and the worker B takes the session over and       *)
(* writes its lines, which rank above A's. A wakes later, and the write it *)
(* had on its way lands; it writes nothing more, as libfx's worker does    *)
(* once its own clock says its lease ran out (DurableSession.tla           *)
(* LateLine). Where that late chunk goes is the World's: with PlaceAtStart *)
(* a chunk's place is fixed when its write starts, as world-local fixes it *)
(* by the id it gives the chunk then, so A's late chunk goes ahead of B's  *)
(* lines and moves every later line one place on, under a reader that     *)
(* already had them (UiStreamWitness-LateLine). Without it a chunk's place *)
(* is where it lands, as in memory() and Vercel's World, where the server  *)
(* places each chunk as it arrives: A's late chunk goes after B's lines,   *)
(* where readers hide it by its epoch, and no cursor moves.                *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Lines,           \* how many lines A writes
    OneByOne,        \* libfx writes a line only once the one before it is visible
    WorldKeepsOrder, \* the World makes a batch's chunks visible in order
    Takeover,        \* A can freeze with a write on its way, and B take over
    TakeoverLines,   \* how many lines B writes
    PlaceAtStart     \* a chunk's place is fixed when its write starts

ASSUME Lines \in Nat /\ TakeoverLines \in Nat
ASSUME OneByOne \in BOOLEAN /\ WorldKeepsOrder \in BOOLEAN
ASSUME Takeover \in BOOLEAN /\ PlaceAtStart \in BOOLEAN

Writers == IF Takeover THEN {"A", "B"} ELSE {"A"}
Count(w) == IF w = "A" THEN Lines ELSE TakeoverLines
\* A chunk: writer w's line n.
Chunks == {[w |-> w, n |-> n] : w \in {"A", "B"}, n \in 1..Lines + TakeoverLines}

VARIABLES
    pushed,    \* lines 1..pushed[w] of each worker are pushed
    sent,      \* lines 1..sent[w] have had their writes started
    inflight,  \* each worker's chunks whose write started and that are not visible yet
    starts,    \* every chunk, in the order its write started
    lands,     \* every visible chunk, in the order it became visible
    frozen,    \* "no", "frozen" while A is frozen, "woke" once it woke
    live,      \* the chunks the live reader took, in the order it took them
    act        \* the step that led here

vars == <<pushed, sent, inflight, starts, lands, frozen, live, act>>

Range(s) == {s[i] : i \in DOMAIN s}
IndexOf(s, x) == CHOOSE i \in DOMAIN s : s[i] = x
\* A visible chunk's place in the stored stream.
Place(c) == IF PlaceAtStart THEN IndexOf(starts, c) ELSE IndexOf(lands, c)
MinPlace(set) == CHOOSE c \in set : \A d \in set : Place(c) <= Place(d)
\* The stream as a replay from cursor 0 reads it now: its visible chunks in
\* place order.
Replay == [i \in 1..Len(lands) |-> CHOOSE c \in Range(lands) : Cardinality({d \in Range(lands) : Place(d) <= Place(c)}) = i]

TypeOK ==
    /\ pushed \in [{"A", "B"} -> 0..Lines + TakeoverLines]
    /\ sent \in [{"A", "B"} -> 0..Lines + TakeoverLines]
    /\ inflight \in [{"A", "B"} -> SUBSET Chunks]
    /\ starts \in Seq(Chunks) /\ lands \in Seq(Chunks) /\ live \in Seq(Chunks)
    /\ frozen \in {"no", "frozen", "woke"}
    /\ act \in {"Init", "Push", "Write", "Land", "Take", "Freeze", "Wake"}

Init ==
    /\ pushed = [w \in {"A", "B"} |-> 0]
    /\ sent = [w \in {"A", "B"} |-> 0]
    /\ inflight = [w \in {"A", "B"} |-> {}]
    /\ starts = <<>> /\ lands = <<>>
    /\ frozen = "no"
    /\ live = <<>>
    /\ act = "Init"

\* Whether w runs: A until it freezes, and B once A froze.
Runs(w) == IF w = "A" THEN frozen = "no" ELSE frozen # "no"

\* w pushes its next line.
Push(w) ==
    /\ Runs(w)
    /\ pushed[w] < Count(w)
    /\ pushed' = [pushed EXCEPT ![w] = pushed[w] + 1]
    /\ UNCHANGED <<sent, inflight, starts, lands, frozen, live>>
    /\ act' = "Push"

\* No write of w's is in flight, so the lines it pushed since its last one
\* go out: together, or only the first of them when libfx writes one by one.
Write(w) ==
    /\ Runs(w)
    /\ inflight[w] = {}
    /\ sent[w] < pushed[w]
    /\ LET last == IF OneByOne /\ ~WorldKeepsOrder THEN sent[w] + 1 ELSE pushed[w]
           batch == [k \in 1..(last - sent[w]) |-> [w |-> w, n |-> sent[w] + k]]
       IN /\ inflight' = [inflight EXCEPT ![w] = Range(batch)]
          /\ starts' = starts \o batch
          /\ sent' = [sent EXCEPT ![w] = last]
    /\ UNCHANGED <<pushed, lands, frozen, live>>
    /\ act' = "Write"

\* One chunk of w's write in flight becomes visible: any of them when the
\* World writes them in parallel, the first when it keeps their order. A
\* frozen worker's write lands only once it wakes.
Land(w) ==
    /\ w \in Writers
    /\ ~(w = "A" /\ frozen = "frozen")
    /\ inflight[w] # {}
    /\ \E c \in inflight[w] :
          /\ WorldKeepsOrder => \A d \in inflight[w] : c.n <= d.n
          /\ inflight' = [inflight EXCEPT ![w] = inflight[w] \ {c}]
          /\ lands' = Append(lands, c)
    /\ UNCHANGED <<pushed, sent, starts, frozen, live>>
    /\ act' = "Land"

\* A freezes with a write on its way, and B takes the session over.
Freeze ==
    /\ Takeover
    /\ frozen = "no"
    /\ inflight["A"] # {}
    /\ frozen' = "frozen"
    /\ UNCHANGED <<pushed, sent, inflight, starts, lands, live>>
    /\ act' = "Freeze"

\* A wakes; its write on its way can land again.
Wake ==
    /\ frozen = "frozen"
    /\ frozen' = "woke"
    /\ UNCHANGED <<pushed, sent, inflight, starts, lands, live>>
    /\ act' = "Wake"

\* The live reader takes the visible chunk with the lowest place it has not
\* had.
Take ==
    /\ Range(lands) \ Range(live) # {}
    /\ live' = Append(live, MinPlace(Range(lands) \ Range(live)))
    /\ UNCHANGED <<pushed, sent, inflight, starts, lands, frozen>>
    /\ act' = "Take"

Next == (\E w \in Writers : Push(w) \/ Write(w) \/ Land(w)) \/ Freeze \/ Wake \/ Take

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

\* A replay from cursor 0 reads the stored stream in place order. The live
\* reader's line i is that replay's line i, now and after every later
\* landing: no line the reader already has changes its cursor.
LiveIsReplay == \A i \in 1..Len(live) : i <= Len(Replay) /\ live[i] = Replay[i]

=============================================================================

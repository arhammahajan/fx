--------------------------- MODULE ViewerAdmission ---------------------------
EXTENDS Naturals

(* Admission's viewer boundary only. The stream position must resolve before
   storing the input that can produce new lines. Its read may overlap a log
   read. A failed stream lookup resolves to the empty start in the SDK and
   is represented by ViewerReady too. Queueing still follows persistence.
   This model does not model leases or establish crash recovery; the adjacent
   BackstopAdmission witness covers the rejected queue-before-log change. *)
CONSTANTS OverlapReads, WaitBeforeWrite
VARIABLES viewerReady, logRead, stored, queued, accepted
vars == <<viewerReady, logRead, stored, queued, accepted>>
Init == /\ viewerReady = FALSE /\ logRead = FALSE
        /\ stored = FALSE /\ queued = FALSE /\ accepted = FALSE
ViewerReady == /\ ~viewerReady /\ viewerReady' = TRUE
               /\ UNCHANGED <<logRead, stored, queued, accepted>>
ReadLog == /\ ~logRead /\ (OverlapReads \/ viewerReady)
           /\ logRead' = TRUE
           /\ UNCHANGED <<viewerReady, stored, queued, accepted>>
Store == /\ logRead /\ ~stored /\ (~WaitBeforeWrite \/ viewerReady)
         /\ stored' = TRUE
         /\ UNCHANGED <<viewerReady, logRead, queued, accepted>>
Enqueue == /\ stored /\ ~queued /\ queued' = TRUE
           /\ UNCHANGED <<viewerReady, logRead, stored, accepted>>
Accept == /\ queued /\ ~accepted /\ accepted' = TRUE
          /\ UNCHANGED <<viewerReady, logRead, stored, queued>>
Next == ViewerReady \/ ReadLog \/ Store \/ Enqueue \/ Accept
Spec == Init /\ [][Next]_vars
TypeOK == /\ viewerReady \in BOOLEAN /\ logRead \in BOOLEAN
          /\ stored \in BOOLEAN /\ queued \in BOOLEAN /\ accepted \in BOOLEAN
ViewerBeforeWrites == stored => viewerReady
AcceptedStoredAndQueued == accepted => (stored /\ queued)
=============================================================================

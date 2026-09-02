import QtQuick
import QtTest
import ".."

// The focus rules that three separate bugs violated, pinned down.
//
// Run with:  qmltestrunner -input tests/
//
// FocusArbiter deliberately depends on nothing but QtQuick, so these run
// without the Omarchy shell's import path or a live Roon core.
TestCase {
  id: testCase
  name: "FocusArbiter"
  when: windowShown
  width: 200
  height: 200

  Item { id: fallback; objectName: "fallback"; focus: true }
  Item { id: fieldA; objectName: "fieldA" }
  Item { id: fieldB; objectName: "fieldB" }

  FocusArbiter {
    id: arbiter
    defaultTarget: fallback
  }

  function init() {
    arbiter.release()
    wait(0)
  }

  function test_default_target_holds_focus_at_rest() {
    verify(fallback.activeFocus, "fallback should hold focus when nothing is claimed")
    verify(!arbiter.claimed)
  }

  function test_claim_moves_focus_to_the_field() {
    arbiter.claim(fieldA)
    verify(arbiter.claimed, "claimed should be true immediately, before the event loop settles")
    wait(0)
    verify(fieldA.activeFocus, "the claimed field should hold focus")
    verify(!fallback.activeFocus)
  }

  function test_release_returns_focus_to_the_default() {
    arbiter.claim(fieldA)
    wait(0)
    arbiter.release()
    wait(0)
    verify(fallback.activeFocus, "focus should return to the default target")
    verify(!arbiter.claimed)
  }

  // The actual bug: a release scheduled before a claim used to land after it
  // and steal focus straight back out of the box the user just opened.
  function test_claim_after_release_in_the_same_turn_wins() {
    arbiter.release()
    arbiter.claim(fieldA)
    wait(0)
    verify(fieldA.activeFocus, "the later claim must beat the earlier release")
    verify(arbiter.claimed)
  }

  // And the mirror case: closing a box must not be undone by a stale claim.
  function test_release_after_claim_in_the_same_turn_wins() {
    arbiter.claim(fieldA)
    arbiter.release()
    wait(0)
    verify(fallback.activeFocus, "the later release must beat the earlier claim")
    verify(!arbiter.claimed)
  }

  function test_last_of_several_claims_wins() {
    arbiter.claim(fieldA)
    arbiter.claim(fieldB)
    wait(0)
    verify(fieldB.activeFocus, "the most recent claim should own focus")
    verify(!fieldA.activeFocus)
  }

  function test_claiming_nothing_changes_nothing() {
    arbiter.claim(null)
    wait(0)
    verify(fallback.activeFocus, "a null claim must not strand focus")
    verify(!arbiter.claimed)
  }

  function test_no_default_target_does_not_throw() {
    var previous = arbiter.defaultTarget
    arbiter.defaultTarget = null
    arbiter.release()
    wait(0)
    arbiter.defaultTarget = previous
    verify(true, "release with no default target should be a no-op, not a crash")
  }
}

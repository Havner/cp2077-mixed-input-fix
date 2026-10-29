// MixedInputQuickMeleeWorkaround 0.1 - EXPERIMENTAL, optional companion mod for MixedInputFix.
//
// Quick melee, and the dual-pistol Valentino's Frenzy that 2.5 put on the same
// button, react to the PRESS of the button instead of a native tap, so they
// keep working while the other input device is streaming: mouse /
// gyro-to-mouse in controller mode, analog stick in kbm mode.
//
// Why they break (vanilla, game 2.5, any MixedInputFix mode or none). Both
// wait for the release twice over (2.5 decompile):
//
//   QuickMeleeDecisions            weaponTransitions.swift
//     OnAction        EnableOnEnterCondition(IsButtonJustReleased)   :1329
//     EnterCondition  IsActionJustTapped('QuickMelee')                :1335
//   ValentinosFrenzyInitDecisions  shootTransitions.swift
//     OnAction        IsButtonJustReleased -> EnableOnEnterCondition  :312
//     EnterCondition  IsActionJustTapped('QuickMelee')                :320
//
// While the other device floods, the engine keeps delivering every PRESS of
// the button to script listeners but drops the RELEASE (measured on Dodge /
// ToggleCrouch, see MixedInputCrouchDodgeWorkaround and RE-notes.md, "Game
// 2.5: lost release edges"). With no release the enter condition is never
// even evaluated, and no tap ever happens.
//
// Why a tap in the first place: with the Alternative controller layout LB
// carries quick melee (tap, QuickMelee_Button_Alternative) and the scanner
// (hold, Vision_Hold_Button + <hold action="VisionHold" timeout="0.1"> in
// inputContexts.xml). Telling those apart needs the release, which is exactly
// what gets lost. So the companion XML takes one of the two off LB, and the
// press becomes unambiguous.
//
// The fix. Both decisions already listen for QuickMelee; their listeners now
// enable the enter condition on PRESSED and record the frame. The enter
// conditions (2.5 bodies, tap swapped for the press) accept the press only in
// the first couple of frames after it, so a press made where the attack can't
// start (reload, menus, vehicles) doesn't fire later out of context. Holding
// the button attacks once, like a tap did. Which of the two a press starts is
// still vanilla's call (CanQuickMelee / CanStartValentinosFrenzy).
//
// Not replaced: NoAmmoDecisions.ExitCondition (weaponTransitions.swift:1632)
// also checks the tap, but quick melee with an empty magazine works without
// it in testing.
//
// Needs one of the two companion MixedInputQuickMeleeWorkaround.xml variants
// in r6/input/ (merged by input_loader). Both cut the scanner's 0.1 s hold
// delay away, so the scanner comes on as soon as it's pressed:
//
//   lb-does-only-quick-melee  LB = quick melee. The scanner leaves the pad
//                             (Tab, or whatever key is bound to "Scanner
//                             (hold)"). Alternative's quick melee is mirrored
//                             onto the default layer, which the pad falls
//                             back to under the flood (vanilla has R3 there).
//   lb-does-only-scanner      LB = scanner. Quick melee leaves the pad (Q, or
//                             whatever key is bound to "Quick Melee"). Needs
//                             the Ping workaround below.
//
// Either way the off-pad action can be put on a Steam Input / Deckhand back
// button mapped to its key.
//
// Not inert without MixedInputFix's pin: quick melee acts on press for
// everyone, in every layout and on the keyboard. The replaced methods must be
// re-checked against the game scripts on every patch (bodies are game 2.5).
//
// Install: r6/scripts/MixedInputQuickMeleeWorkaround/MixedInputQuickMeleeWorkaround.reds
//          r6/input/MixedInputQuickMeleeWorkaround.xml, copied from
//          r6/input-lb-does-only-quick-melee/ or r6/input-lb-does-only-scanner/
// Requires: redscript, input_loader.

// A press counts only in the first couple of frames after it.
public func MixedInputQuickMelee_IsFresh(game: GameInstance, pressFrame: Uint64) -> Bool {
  let frame: Uint64 = GameInstance.GetFrameNumber(game);
  return frame >= pressFrame && frame - pressFrame <= 2ul;
}

// ---- Quick melee ----

@addField(QuickMeleeDecisions) private let m_miqmPressFrame: Uint64;

// weaponTransitions.swift:1329. Vanilla: this.EnableOnEnterCondition(ListenerAction.IsButtonJustReleased(action)).
@replaceMethod(QuickMeleeDecisions)
protected cb func OnAction(action: ListenerAction, consumer: ListenerActionConsumer) -> Bool {
  if ListenerAction.IsButtonJustPressed(action) {
    this.m_miqmPressFrame = GameInstance.GetFrameNumber(GetGameInstance());
    this.EnableOnEnterCondition(true);
  };
  return false;
}

// :1333. Tap swapped for the press recorded above.
@replaceMethod(QuickMeleeDecisions)
protected final const func EnterCondition(const stateContext: ref<StateContext>, const scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  this.EnableOnEnterCondition(false);
  if MixedInputQuickMelee_IsFresh(scriptInterface.GetGame(), this.m_miqmPressFrame) {
    return this.CanQuickMelee(stateContext, scriptInterface);
  };
  return false;
}

// ---- Scanner on LB (lb-does-only-scanner/MixedInputQuickMeleeWorkaround.xml) ----
//
// With the Alternative layout the engine still treats LB as tap-or-hold for
// the scanner, even with quick melee moved off it: an LB press sends no
// VisionHold PRESSED, a VisionHold RELEASED right away, and HOLD_COMPLETE only
// ~0.3 s later, whatever the <hold> timeout says (probe, 2026-10-29). Legacy
// and Tab send VisionHold PRESSED at once. Ping shares the scanner's mapping
// (Vision_Hold_Button) and gets clean PRESSED / RELEASED edges on LB, and on
// Alternative it doesn't pulse (hudManager.swift:534). So on Alternative the
// scanner hold follows Ping, and a VisionHold release while Ping is still
// held is ignored. Where Ping isn't mapped (DriverCombatVisionActions),
// VisionHold stays vanilla. With lb-does-only-quick-melee, Ping comes only
// from Tab, together with VisionHold, and nothing changes.

public func MixedInputQuickMelee_IsAlternative(game: GameInstance) -> Bool {
  let inputSchemesBB: ref<IBlackboard> = GameInstance.GetBlackboardSystem(game).Get(GetAllBlackboardDefs().InputSchemes);
  // PC numbering, see ConvertIntValueToInputScheme.
  return IsDefined(inputSchemesBB) && inputSchemesBB.GetUint(GetAllBlackboardDefs().InputSchemes.Scheme) == 2u;
}

@addField(PlayerVisionModeController) private let m_miqmPingHeld: Bool;

// playerVisionModeController.swift:76.
@wrapMethod(PlayerVisionModeController)
private final func RegisterInputListeners() -> Void {
  wrappedMethod();
  this.m_owner.RegisterInputListener(this, n"Ping");
}

// :258. The Ping branch is vanilla's VisionHold value handling (:293).
@wrapMethod(PlayerVisionModeController)
protected cb func OnAction(action: ListenerAction, consumer: ListenerActionConsumer) -> Bool {
  let name: CName = ListenerAction.GetName(action);
  if Equals(name, n"Ping") {
    this.m_miqmPingHeld = ListenerAction.GetValue(action) > 0.00;
    if MixedInputQuickMelee_IsAlternative(this.m_owner.GetGame()) {
      if this.m_miqmPingHeld {
        this.m_inputActiveFlags.m_buttonHold = true;
        this.m_otherVars.m_toggledDuringHold = false;
      } else {
        this.m_inputActiveFlags.m_buttonHold = false;
        if !this.m_otherVars.m_toggledDuringHold {
          this.m_inputActiveFlags.m_buttonToggle = false;
        };
      };
      this.VerifyActivation();
    };
    return false;
  };
  if Equals(name, n"VisionHold") && this.m_miqmPingHeld && ListenerAction.GetValue(action) <= 0.00 && MixedInputQuickMelee_IsAlternative(this.m_owner.GetGame()) {
    return false;
  };
  return wrappedMethod(action, consumer);
}

// ---- Valentino's Frenzy (dual pistols) ----

@addField(ValentinosFrenzyInitDecisions) private let m_miqmPressFrame: Uint64;

// shootTransitions.swift:312. Vanilla enables on IsButtonJustReleased.
@replaceMethod(ValentinosFrenzyInitDecisions)
protected cb func OnAction(action: ListenerAction, consumer: ListenerActionConsumer) -> Bool {
  if ListenerAction.IsButtonJustPressed(action) {
    this.m_miqmPressFrame = GameInstance.GetFrameNumber(GetGameInstance());
    this.EnableOnEnterCondition(true);
  };
  return false;
}

// :318. Tap swapped for the press recorded above.
@replaceMethod(ValentinosFrenzyInitDecisions)
protected final const func EnterCondition(const stateContext: ref<StateContext>, const scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  this.EnableOnEnterCondition(false);
  return MixedInputQuickMelee_IsFresh(scriptInterface.GetGame(), this.m_miqmPressFrame) && this.CanStartValentinosFrenzy(stateContext, scriptInterface);
}

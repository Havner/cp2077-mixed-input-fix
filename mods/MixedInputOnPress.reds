// MixedInputOnPress 0.1 - HEAVILY EXPERIMENTAL, optional companion mod for MixedInputFix.
//
// Dodge and toggle crouch (crouch, stand up, slide) react to the PRESS of
// their button instead of a native tap, so they keep working while the other
// input device is streaming: mouse / gyro-to-mouse in controller mode, analog
// stick in kbm mode.
//
// Why they break (vanilla, game 2.5, any MixedInputFix mode or none). Both
// actions trigger on IsActionJustTapped (press + quick release):
//
//   WantsToDodge          IsActionJustTapped('Dodge')       locomotionTransitions.script:352
//   toggle crouch, all    IsActionJustTapped('ToggleCrouch') :752 :781 :804 :820 :1750 :2490
//
// While the other device floods, the engine keeps delivering every PRESS of
// the button to script listeners but drops the RELEASE, so the action latches
// held and no tap ever happens. Measured with a probe on DodgeDecisions and
// CrouchDecisions:
//
//   pad only:          PRESSED, RELEASED 0.06 s later, justTapped=true
//   gyro-to-mouse, B:  PRESSED x25 over 7 s, no RELEASED, value stuck at 1,
//                      justTapped=false (same for R3 / ToggleCrouch)
//   kbm, stick + C:    PRESSED x25 over 5 s, same
//   late RELEASED:     only after the flood stops - far too long for a tap
//
// The native IsActionJustPressed is no way out either: with the action stuck
// at 1 it is false for every press after the first. The listener PRESSED
// edges are what survives.
//
// The fix. PlayerPuppet's input listener records each Dodge / ToggleCrouch
// PRESSED edge. MixedInputOnPressButton turns that into a one-frame "just
// pressed": true for every caller during the first PSM frame that asks after
// the press, false afterwards - the same shape as a native tap, so all
// consumers of one press agree, in vanilla's own order (sprint -> slide still
// beats sprint -> crouch). Each consumer of the tap is replaced below, with the
// 2.5 body kept as is and only the tap swapped for the press. The late
// release no longer means anything to them.
//
// Only with the Alternative controller layout: there the dodge button (B /
// IK_LControl) and the crouch button (R3 / IK_C) carry nothing else in
// Locomotion, so a press is unambiguous. In Legacy/Agile crouch and dodge
// share one button (tap/double-tap), and everything stays vanilla.
//
// Needs the companion inputUserMappings.xml (shipped with it as
// MixedInputCrouchDodgeWorkaround): under the flood the pad falls back from
// the selected layout to the default layer, where vanilla binds crouch AND
// dodge to B and quick melee to R3. The XML mirrors Alternative into the
// default layer and adds the keyboard keys to the Alternative variants -
// see MixedInputFix's RE-notes.md, "Known issue: crouch/dodge loss".
//
// Not covered, still tap-based: directional double-tap dodges, low gravity,
// ladder crouch, air thrusters / hover, scene fast-forward by crouch, the
// crouched-dodge state carry-over (DodgeEvents). Hold crouch (Crouch,
// IK_RControl) is value-based and unaffected.
//
// Not inert without MixedInputFix's pin: with the Alternative layout, dodge
// and toggle crouch act on press for everyone. Replaced methods must be
// re-checked against the game scripts on every patch (bodies are game 2.5).
//
// Install: r6/scripts/MixedInputOnPress/MixedInputOnPress.reds
// Requires: redscript.

// ---- Press tracking ----

public class MixedInputOnPressButton {
  private let m_pending: Bool;
  private let m_pressFrame: Uint64;
  private let m_activeFrame: Uint64;

  public func OnPress(frame: Uint64) -> Void {
    this.m_pending = true;
    this.m_pressFrame = frame;
  }

  // The first frame that asks after a press becomes that press's active
  // frame. A press nobody asked about within a couple of frames (menus,
  // vehicles, states without these actions) is dropped, so it can't fire
  // later out of context.
  public func JustPressed(frame: Uint64) -> Bool {
    if this.m_pending {
      this.m_pending = false;
      if frame >= this.m_pressFrame && frame - this.m_pressFrame <= 2ul {
        this.m_activeFrame = frame;
      };
    };
    return this.m_activeFrame == frame;
  }
}

@addField(PlayerPuppet) private let m_miopDodge: ref<MixedInputOnPressButton>;
@addField(PlayerPuppet) private let m_miopToggleCrouch: ref<MixedInputOnPressButton>;

// Vanilla 2.5 already listens for Dodge here (player.script:1250).
@wrapMethod(PlayerPuppet)
protected cb func OnGameAttached() -> Bool {
  let result: Bool;
  this.m_miopDodge = new MixedInputOnPressButton();
  this.m_miopToggleCrouch = new MixedInputOnPressButton();
  result = wrappedMethod();
  if this.IsControlledByLocalPeer() || IsHost() {
    this.RegisterInputListener(this, n"ToggleCrouch");
  };
  return result;
}

@wrapMethod(PlayerPuppet)
protected cb func OnAction(action: ListenerAction, consumer: ListenerActionConsumer) -> Bool {
  let button: ref<MixedInputOnPressButton>;
  if ListenerAction.IsButtonJustPressed(action) {
    button = this.MixedInputOnPress_Button(ListenerAction.GetName(action));
    if IsDefined(button) {
      button.OnPress(GameInstance.GetFrameNumber(this.GetGame()));
    };
  };
  return wrappedMethod(action, consumer);
}

@addMethod(PlayerPuppet)
private func MixedInputOnPress_Button(actionName: CName) -> ref<MixedInputOnPressButton> {
  if Equals(actionName, n"Dodge") {
    return this.m_miopDodge;
  };
  if Equals(actionName, n"ToggleCrouch") {
    return this.m_miopToggleCrouch;
  };
  return null;
}

@addMethod(PlayerPuppet)
public func MixedInputOnPress_JustPressed(actionName: CName) -> Bool {
  let button: ref<MixedInputOnPressButton> = this.MixedInputOnPress_Button(actionName);
  return IsDefined(button) && button.JustPressed(GameInstance.GetFrameNumber(this.GetGame()));
}

// ---- The swapped conditions ----

public func MixedInputOnPress_IsAlternative(game: GameInstance) -> Bool {
  let inputSchemesBB: ref<IBlackboard> = GameInstance.GetBlackboardSystem(game).Get(GetAllBlackboardDefs().InputSchemes);
  // PC numbering, see ConvertIntValueToInputScheme (gamepadInputScheme.script:16).
  return IsDefined(inputSchemesBB) && inputSchemesBB.GetUint(GetAllBlackboardDefs().InputSchemes.Scheme) == 2u;
}

// Replaces IsActionJustTapped('Dodge').
public func MixedInputOnPress_DodgePressed(const scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  let player: ref<PlayerPuppet> = scriptInterface.executionOwner as PlayerPuppet;
  if IsDefined(player) && MixedInputOnPress_IsAlternative(scriptInterface.GetGame()) {
    return player.MixedInputOnPress_JustPressed(n"Dodge");
  };
  return scriptInterface.IsActionJustTapped(n"Dodge");
}

// Replaces IsActionJustTapped('ToggleCrouch') || IsActionJustHeld('ToggleCrouch').
public func MixedInputOnPress_ToggleCrouchPressed(const scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  let player: ref<PlayerPuppet> = scriptInterface.executionOwner as PlayerPuppet;
  if IsDefined(player) && MixedInputOnPress_IsAlternative(scriptInterface.GetGame()) {
    return player.MixedInputOnPress_JustPressed(n"ToggleCrouch");
  };
  return scriptInterface.IsActionJustTapped(n"ToggleCrouch") || scriptInterface.IsActionJustHeld(n"ToggleCrouch");
}

// ---- Replaced vanilla methods (game 2.5 bodies, tap swapped for press) ----

// locomotionTransitions.script:322. Ground dodge (DodgeDecisions) and air
// dash (DodgeAirDecisions).
@replaceMethod(LocomotionTransition)
protected final const func WantsToDodge(const stateContext: ref<StateContext>, const scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  let disableAirDash: StateResultBool;
  let isAirDashPerkBought: Bool;
  let isInCooldown: Bool;
  let isStaminaPositive: Bool;
  if !scriptInterface.HasStatFlag(gamedataStatType.HasDodge) {
    return false;
  };
  if StatusEffectSystem.ObjectHasStatusEffect(scriptInterface.executionOwner, t"BaseStatusEffect.HealFood3") {
    return false;
  };
  isInCooldown = StatusEffectSystem.ObjectHasStatusEffect(scriptInterface.executionOwner, t"BaseStatusEffect.DodgeCooldown") || StatusEffectSystem.ObjectHasStatusEffect(scriptInterface.executionOwner, t"BaseStatusEffect.DodgeAirCooldown");
  if isInCooldown {
    return false;
  };
  disableAirDash = stateContext.GetPermanentBoolParameter(n"disableAirDash");
  isAirDashPerkBought = PlayerDevelopmentSystem.GetInstance(scriptInterface.executionOwner).IsNewPerkBought(scriptInterface.executionOwner, gamedataNewPerkType.Reflexes_Central_Milestone_3) == 3;
  isStaminaPositive = GameInstance.GetStatPoolsSystem(scriptInterface.executionOwner.GetGame()).GetStatPoolValue(Cast<StatsObjectID>(scriptInterface.executionOwner.GetEntityID()), gamedataStatPoolType.Stamina, true) > 0.00;
  if !this.IsTouchingGround(scriptInterface) && (!isAirDashPerkBought || !isStaminaPositive || disableAirDash.valid && disableAirDash.value) {
    return false;
  };
  if this.IsCurrentFallSpeedTooFastToEnter(stateContext, scriptInterface) {
    return false;
  };
  if MixedInputOnPress_DodgePressed(scriptInterface) || scriptInterface.IsPatternJustActivated(n"Dodge") {
    if scriptInterface.IsMoveInputConsiderable() {
      stateContext.SetConditionFloatParameter(n"DodgeDirection", scriptInterface.GetInputHeading(), true);
      return true;
    };
    if this.GetStaticBoolParameterDefault("dodgeWithNoMovementInput", false) {
      stateContext.SetConditionFloatParameter(n"DodgeDirection", -180.00, true);
      return true;
    };
  };
  if this.WantsToDodgeFromMovementInput(stateContext, scriptInterface) && GameplaySettingsSystem.GetMovementDodgeEnabled(scriptInterface.executionOwner) {
    return true;
  };
  return false;
}

// :740. Toggle crouch from stand / sprint / slide events.
@replaceMethod(LocomotionEventsTransition)
protected final func UpdateInputToggles(stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>, minTimeBeforeCrouch: Float, dontToggleCrouchOffOnSprint: Bool, out toggledSprint: Bool, out toggledCrouch: Bool) -> Void {
  if scriptInterface.IsActionJustPressed(n"ToggleSprint") || scriptInterface.IsActionJustPressed(n"Sprint") {
    stateContext.SetConditionBoolParameter(n"SprintToggled", true, true);
    if !dontToggleCrouchOffOnSprint {
      stateContext.SetConditionBoolParameter(n"CrouchToggled", false, true);
    };
    toggledSprint = true;
    return;
  };
  if this.GetInStateTime() > minTimeBeforeCrouch && MixedInputOnPress_ToggleCrouchPressed(scriptInterface) {
    stateContext.SetConditionBoolParameter(n"CrouchToggled", true, true);
    stateContext.SetConditionBoolParameter(n"SprintToggled", false, true);
    stateContext.SetConditionBoolParameter(n"SprintHoldCanStartWithoutNewInput", false, true);
    toggledCrouch = true;
    return;
  };
}

// :779. Crouch on landing.
@replaceMethod(LocomotionGroundDecisions)
public final static func CheckCrouchEnterCondition(const stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  if MixedInputOnPress_ToggleCrouchPressed(scriptInterface) || stateContext.GetConditionBool(n"CrouchToggled") {
    stateContext.SetConditionBoolParameter(n"CrouchToggled", true, true);
    return true;
  };
  return scriptInterface.GetActionValue(n"Crouch") > 0.00;
}

// :789. Stand / sprint -> crouch, and slide through SlideDecisions'
// super.EnterCondition.
@replaceMethod(LocomotionGroundDecisions)
protected final const func CrouchEnterCondition(const stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>, isFFByLine: Bool) -> Bool {
  let puppetPS: ref<ScriptedPuppetPS>;
  let paramName: CName = isFFByLine ? n"FFhintActive" : n"FFHoldLock";
  let puppet: ref<ScriptedPuppet> = scriptInterface.owner as ScriptedPuppet;
  if IsDefined(puppet) {
    puppetPS = puppet.GetPuppetPS();
  };
  if StatusEffectSystem.ObjectHasStatusEffectWithTag(scriptInterface.executionOwner, n"FocusModeLocomotion") {
    return false;
  };
  if (MixedInputOnPress_ToggleCrouchPressed(scriptInterface) || stateContext.GetConditionBool(n"CrouchToggled")) && !stateContext.GetBoolParameter(paramName, true) || IsDefined(puppetPS) && puppetPS.IsCrouch() {
    stateContext.SetConditionBoolParameter(n"CrouchToggled", true, true);
    return true;
  };
  return scriptInterface.GetActionValue(n"Crouch") > 0.00;
}

// :812. Crouch / crouch-sprint -> stand.
@replaceMethod(LocomotionGroundDecisions)
protected final const func CrouchExitCondition(const stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>, isFFByLine: Bool) -> Bool {
  let paramName: CName;
  if StatusEffectSystem.ObjectHasStatusEffectWithTag(scriptInterface.executionOwner, n"FocusModeLocomotion") {
    return false;
  };
  paramName = isFFByLine ? n"FFhintActive" : n"FFHoldLock";
  if (scriptInterface.IsActionJustReleased(n"Crouch") || MixedInputOnPress_ToggleCrouchPressed(scriptInterface)) && !stateContext.GetBoolParameter(paramName, true) {
    stateContext.SetConditionBoolParameter(n"CrouchToggled", false, true);
    return true;
  };
  if !stateContext.GetConditionBool(n"CrouchToggled") && scriptInterface.GetActionValue(n"Crouch") == 0.00 {
    return true;
  };
  return false;
}

// :1738. Crouch-sprint -> crouch.
@replaceMethod(CrouchSprintDecisions)
protected const func ToCrouch(const stateContext: ref<StateContext>, const scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  let minLinearVelocityThreshold: Float;
  let minStickInputThreshold: Float;
  if !this.IsTouchingGround(scriptInterface) {
    return false;
  };
  if this.GetInStateTime() < this.GetStaticFloatParameterDefault("minTimeToExit", 1.00) {
    return false;
  };
  if scriptInterface.IsActionJustPressed(n"Crouch") || scriptInterface.IsActionJustPressed(n"Jump") || MixedInputOnPress_ToggleCrouchPressed(scriptInterface) {
    stateContext.SetConditionBoolParameter(n"CrouchToggled", false, true);
    return true;
  };
  if !scriptInterface.HasStatFlag(gamedataStatType.CanSprint) || scriptInterface.IsActionJustReleased(n"Sprint") || scriptInterface.IsActionJustPressed(n"ToggleSprint") {
    stateContext.SetConditionBoolParameter(n"SprintToggled", false, true);
    stateContext.SetConditionBoolParameter(n"SprintHoldCanStartWithoutNewInput", false, true);
    return true;
  };
  if stateContext.GetBoolParameter(n"WalkToggled", true) {
    stateContext.SetConditionBoolParameter(n"SprintToggled", false, true);
    stateContext.SetConditionBoolParameter(n"SprintHoldCanStartWithoutNewInput", false, true);
    return true;
  };
  if this.GetInStateTime() >= 0.60 {
    minLinearVelocityThreshold = this.GetStaticFloatParameterDefault("minLinearVelocityThreshold", 0.50);
    if scriptInterface.GetOwnerStateVectorParameterFloat(physicsStateValue.LinearSpeed) < minLinearVelocityThreshold {
      stateContext.SetConditionBoolParameter(n"SprintToggled", false, true);
      stateContext.SetConditionBoolParameter(n"SprintHoldCanStartWithoutNewInput", false, true);
      return true;
    };
  };
  if !scriptInterface.IsMoveInputConsiderable() {
    stateContext.SetConditionBoolParameter(n"SprintToggled", false, true);
    stateContext.SetConditionBoolParameter(n"SprintHoldCanStartWithoutNewInput", false, true);
    return true;
  };
  minStickInputThreshold = this.GetStaticFloatParameterDefault("minStickInputThreshold", 0.80);
  if stateContext.GetConditionBool(n"SprintToggled") && DefaultTransition.GetMovementInputActionValue(stateContext, scriptInterface) <= minStickInputThreshold {
    stateContext.SetConditionBoolParameter(n"SprintToggled", false, true);
    return true;
  };
  if (scriptInterface.executionOwner as PlayerPuppet).GetStaminaValueUnsafe() <= 1.00 {
    StatusEffectHelper.RemoveStatusEffect(scriptInterface.executionOwner, t"BaseStatusEffect.OpticalCamoCoolPerkShort");
    stateContext.SetConditionBoolParameter(n"SprintToggled", false, true);
    stateContext.SetConditionBoolParameter(n"SprintHoldCanStartWithoutNewInput", false, true);
    return true;
  };
  if scriptInterface.IsActionJustReleased(n"Sprint") {
    stateContext.SetConditionBoolParameter(n"SprintToggled", false, true);
    stateContext.SetConditionBoolParameter(n"SprintHoldCanStartWithoutNewInput", false, true);
    return true;
  };
  return false;
}

// :2476. Slide -> stand.
@replaceMethod(SlideDecisions)
protected const func ToStand(const stateContext: ref<StateContext>, const scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  let forceSlide: StateResultBool;
  if !this.IsTouchingGround(scriptInterface) {
    return false;
  };
  if this.GetInStateTime() < this.GetStaticFloatParameterDefault("minTimeToExit", 1.00) {
    return this.ShouldExit(stateContext, scriptInterface);
  };
  forceSlide = stateContext.GetPermanentBoolParameter(n"forceSlide");
  if !stateContext.GetConditionBool(n"CrouchToggled") && scriptInterface.GetActionValue(n"Crouch") <= 0.00 && !forceSlide.value {
    return true;
  };
  if scriptInterface.IsActionJustReleased(n"Crouch") || scriptInterface.IsActionJustPressed(n"Sprint") || scriptInterface.IsActionJustPressed(n"ToggleSprint") || MixedInputOnPress_ToggleCrouchPressed(scriptInterface) {
    stateContext.SetConditionBoolParameter(n"CrouchToggled", false, true);
    return true;
  };
  return this.ShouldExit(stateContext, scriptInterface);
}

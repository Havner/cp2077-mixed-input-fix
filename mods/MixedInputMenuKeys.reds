// MixedInputMenuKeys 1.0 - optional companion mod for MixedInputFix.
//
// Restores the keyboard menu shortcuts (M / J / P / K / I) while the UI is
// pinned to the gamepad, without changing anything about the pad's Start
// button (tap = player menu, hold = map).
//
// Why they break. inGameMenuGameController.OnAction gates all five shortcut
// actions on the player's last-used input device:
//
//   if HOLD_COMPLETE && !PlayerLastUsedKBM() || RELEASED && PlayerLastUsedKBM()
//
// MixedInputFix pins the device to the gamepad, so PlayerLastUsedKBM() answers
// false and only the hold branch survives. Two consequences, both confirmed
// against the game's input config:
//
//   * Map still works on hold, because OpenMapMenu is the one action with a
//     <hold timeout="0.4"> declaration (r6/config/inputContexts.xml:1436) and
//     the one that lists BUTTON_HOLD_COMPLETE in its acceptedEvents.
//   * Journal / perks / crafting / inventory die completely - tap AND hold -
//     because they accept only BUTTON_PRESSED and BUTTON_RELEASED, so their
//     hold branch can never fire. Vanilla hides this: PlayerLastUsedKBM()
//     turns true the moment you touch a key, so the released branch covers it.
//
// Why the map needs special handling. r6/config/inputUserMappings.xml binds
// OpenHubMenu AND OpenMapMenu to the same physical pad button (IK_Pad_Start,
// IK_PS4_TOUCH_PRESS) - that shared button is the entire reason the device
// check exists. Simply opening the map on release would open the player menu
// and the map together on every Start tap.
//
// Scripts get no per-event device information (ListenerAction exposes only
// GetName/GetType/GetValue/IsButtonJust*/IsAction), so the device cannot be
// asked. What can be observed is that a pad Start press delivers BOTH actions
// in a single input frame, whereas IK_M delivers only OpenMapMenu. Measured:
//
//   t=485779.9688 OpenHubMenu PRESSED     <- pad Start tap: four events,
//   t=485779.9688 OpenHubMenu RELEASED       one timestamp, hub first
//   t=485779.9688 OpenMapMenu PRESSED
//   t=485779.9688 OpenMapMenu RELEASED
//   t=485789.1250 OpenMapMenu PRESSED     <- keyboard M tap: OpenMapMenu
//   t=485789.2188 OpenMapMenu RELEASED       alone, across two frames
//
// So: open the map on release unless an OpenHubMenu event shared the frame.
//
// This mod is inert without a pin. In vanilla the device flips to KBM as the
// key goes down, so PlayerLastUsedKBM() is already true and the early-out
// below takes it out of the picture entirely. Likewise in MixedInputFix's
// kbm mode, where the vanilla released branch works on its own.
//
// Install: r6/scripts/MixedInputMenuKeys/MixedInputMenuKeys.reds
// Requires: redscript. MixedInputFix itself is native-only and unaffected.

// Two input events belong to the same frame. Engine time is sampled once per
// frame, so events dispatched together carry a bit-identical stamp; the epsilon
// is slack, not tolerance.
public func MixedInputMenuKeys_SameFrame(a: Float, b: Float) -> Bool {
  return AbsF(a - b) < 0.001;
}

// Last OpenHubMenu press, and last OpenHubMenu event of any type. The press is
// what a map press is matched against (hub is dispatched first, so it is
// already recorded); the second is a backstop in case that order ever changes.
@addField(gameuiInGameMenuGameController) private let m_mifkHubPressTime: Float;
@addField(gameuiInGameMenuGameController) private let m_mifkHubEventTime: Float;

// Per-press-cycle state for OpenMapMenu.
@addField(gameuiInGameMenuGameController) private let m_mifkMapFromPad: Bool;
@addField(gameuiInGameMenuGameController) private let m_mifkMapHoldFired: Bool;

@wrapMethod(gameuiInGameMenuGameController)
protected cb func OnAction(action: ListenerAction, consumer: ListenerActionConsumer) -> Bool {
  let actionName: CName;
  let actionType: gameinputActionType;
  let now: Float;
  let player: ref<GameObject>;
  let result: Bool = wrappedMethod(action, consumer);

  player = this.GetPlayerControlledObject();
  if !IsDefined(player) || this.m_controllerDisconnected {
    return result;
  };
  // Same suppression vanilla applies at the top of OnAction.
  if Cast<Bool>(GameInstance.GetQuestsSystem(player.GetGame()).GetFact(n"q301_02a_stadium_stopUIInCutscene")) {
    return result;
  };
  // Not pinned away from keyboard/mouse: vanilla already handles these keys.
  if player.PlayerLastUsedKBM() {
    return result;
  };

  actionName = ListenerAction.GetName(action);
  actionType = ListenerAction.GetType(action);
  now = EngineTime.ToFloat(GameInstance.GetEngineTime(player.GetGame()));

  // The shared pad button. Only observed, never acted on - vanilla opens the
  // player menu from this action and that behavior is left exactly as it is.
  if Equals(actionName, n"OpenHubMenu") {
    this.m_mifkHubEventTime = now;
    if Equals(actionType, gameinputActionType.BUTTON_PRESSED) {
      this.m_mifkHubPressTime = now;
    };
    return result;
  };

  // The map, which shares that button and so needs the frame test.
  if Equals(actionName, n"OpenMapMenu") {
    if Equals(actionType, gameinputActionType.BUTTON_PRESSED) {
      this.m_mifkMapHoldFired = false;
      this.m_mifkMapFromPad = MixedInputMenuKeys_SameFrame(this.m_mifkHubPressTime, now);
      return result;
    };
    if Equals(actionType, gameinputActionType.BUTTON_HOLD_COMPLETE) {
      this.m_mifkMapHoldFired = true; // vanilla just opened the map
      return result;
    };
    if Equals(actionType, gameinputActionType.BUTTON_RELEASED) {
      if !this.m_mifkMapHoldFired
         && !this.m_mifkMapFromPad
         && !MixedInputMenuKeys_SameFrame(this.m_mifkHubEventTime, now) {
        this.OpenShortcutMenu(n"OpenMapMenu");
      };
    };
    return result;
  };

  // Keyboard-only shortcuts: no pad binding and no possible hold event, so a
  // release is unambiguous and cannot collide with anything.
  if Equals(actionType, gameinputActionType.BUTTON_RELEASED) {
    if Equals(actionName, n"OpenJournalMenu")
       || Equals(actionName, n"OpenPerksMenu")
       || Equals(actionName, n"OpenInventoryMenu") {
      this.OpenShortcutMenu(actionName);
    };
    if Equals(actionName, n"OpenCraftingMenu") {
      this.TryOpenCraftingMenu(actionName);
    };
  };
  return result;
}

import Testing
import CollectiveKit
@testable import CollectiveUI

/// The roles of the drawn controls: an enabled control's outline is
/// `--border-control`, a disabled one `--border`; what `--accent` fills turns `--accent-hover`
/// when hovered and `--accent-active` when pressed.
@Suite("Control roles")
struct ControlRoleTests {
    private typealias Button = SettingsButtonBody

    @Test func aNormalButtonIsOutlinedByBorderControl() {
        #expect(Button.roles(kind: .normal, isEnabled: true, isPressed: false, isHovered: false)
            == .init(text: .text, border: .borderControl, fill: nil))
        #expect(Button.roles(kind: .normal, isEnabled: true, isPressed: false, isHovered: true)
            == .init(text: .text, border: .borderControl, fill: .surfaceHover))
        #expect(Button.roles(kind: .normal, isEnabled: true, isPressed: true, isHovered: true)
            == .init(text: .text, border: .borderControl, fill: .surfaceActive))
        #expect(Button.roles(kind: .normal, isEnabled: false, isPressed: false, isHovered: true)
            == .init(text: .textDisabled, border: .border, fill: nil))
    }

    @Test func aPrimaryButtonTakesTheAccentStates() {
        #expect(Button.roles(kind: .primary, isEnabled: true, isPressed: false, isHovered: false)
            == .init(text: .accentOn, border: .accent, fill: .accent))
        #expect(Button.roles(kind: .primary, isEnabled: true, isPressed: false, isHovered: true)
            == .init(text: .accentOn, border: .accentHover, fill: .accentHover))
        #expect(Button.roles(kind: .primary, isEnabled: true, isPressed: true, isHovered: true)
            == .init(text: .accentOn, border: .accentActive, fill: .accentActive))
        #expect(Button.roles(kind: .primary, isEnabled: false, isPressed: false, isHovered: true)
            == .init(text: .textDisabled, border: .border, fill: .surfaceRaised))
    }

    @Test func aDestructiveButtonStaysDanger() {
        #expect(Button.roles(kind: .destructive, isEnabled: true, isPressed: false, isHovered: false)
            == .init(text: .danger, border: .danger, fill: nil))
        #expect(Button.roles(kind: .destructive, isEnabled: true, isPressed: false, isHovered: true)
            == .init(text: .danger, border: .danger, fill: .surfaceHover))
        #expect(Button.roles(kind: .destructive, isEnabled: true, isPressed: true, isHovered: true)
            == .init(text: .danger, border: .danger, fill: .surfaceActive))
        #expect(Button.roles(kind: .destructive, isEnabled: false, isPressed: false, isHovered: false)
            == .init(text: .textDisabled, border: .border, fill: nil))
    }

    @Test func aSwitchOnTakesTheAccentStates() {
        #expect(SwitchTrack.roles(isEnabled: true, isOn: true, isPressed: false, isHovered: false)
            == .init(border: .accent, fill: .accent, knob: .accentOn))
        #expect(SwitchTrack.roles(isEnabled: true, isOn: true, isPressed: false, isHovered: true)
            == .init(border: .accentHover, fill: .accentHover, knob: .accentOn))
        #expect(SwitchTrack.roles(isEnabled: true, isOn: true, isPressed: true, isHovered: true)
            == .init(border: .accentActive, fill: .accentActive, knob: .accentOn))
    }

    @Test func aSwitchOffIsOutlinedByBorderControl() {
        #expect(SwitchTrack.roles(isEnabled: true, isOn: false, isPressed: false, isHovered: false)
            == .init(border: .borderControl, fill: .surfaceRaised, knob: .textMuted))
        #expect(SwitchTrack.roles(isEnabled: true, isOn: false, isPressed: false, isHovered: true)
            == .init(border: .borderControl, fill: .surfaceHover, knob: .textMuted))
        #expect(SwitchTrack.roles(isEnabled: true, isOn: false, isPressed: true, isHovered: true)
            == .init(border: .borderControl, fill: .surfaceActive, knob: .text))
    }

    @Test func aDisabledSwitchKeepsItsRoles() {
        #expect(SwitchTrack.roles(isEnabled: false, isOn: true, isPressed: false, isHovered: true)
            == .init(border: .borderStrong, fill: .borderStrong, knob: .surface))
        #expect(SwitchTrack.roles(isEnabled: false, isOn: false, isPressed: false, isHovered: true)
            == .init(border: .border, fill: nil, knob: .textDisabled))
    }

    @Test func aSelectedRadioTakesTheAccentStates() {
        #expect(SettingsRadioBody.markRoles(isSelected: true, isEnabled: true, isPressed: false, isHovered: false)
            == .init(fill: .accent, border: nil, dot: .accentOn))
        #expect(SettingsRadioBody.markRoles(isSelected: true, isEnabled: true, isPressed: false, isHovered: true)
            == .init(fill: .accentHover, border: nil, dot: .accentOn))
        #expect(SettingsRadioBody.markRoles(isSelected: true, isEnabled: true, isPressed: true, isHovered: true)
            == .init(fill: .accentActive, border: nil, dot: .accentOn))
        #expect(SettingsRadioBody.markRoles(isSelected: true, isEnabled: false, isPressed: false, isHovered: true)
            == .init(fill: .borderStrong, border: nil, dot: .surface))
    }

    @Test func anUnselectedRadioIsOutlinedByBorderControl() {
        #expect(SettingsRadioBody.markRoles(isSelected: false, isEnabled: true, isPressed: false, isHovered: false)
            == .init(fill: .surfaceRaised, border: .borderControl, dot: nil))
        #expect(SettingsRadioBody.markRoles(isSelected: false, isEnabled: true, isPressed: false, isHovered: true)
            == .init(fill: .surfaceHover, border: .borderControl, dot: nil))
        #expect(SettingsRadioBody.markRoles(isSelected: false, isEnabled: true, isPressed: true, isHovered: true)
            == .init(fill: .surfaceActive, border: .borderControl, dot: nil))
        #expect(SettingsRadioBody.markRoles(isSelected: false, isEnabled: false, isPressed: false, isHovered: true)
            == .init(fill: nil, border: .border, dot: nil))
    }

    /// Hover and pressed show in the fill only.
    @Test func aPopUpIsOutlinedByBorderControlInEveryState() {
        #expect(SettingsPopUpBody.roles(isEnabled: true, isPressed: false, isHovered: false)
            == .init(border: .borderControl, fill: .surfaceRaised))
        #expect(SettingsPopUpBody.roles(isEnabled: true, isPressed: false, isHovered: true)
            == .init(border: .borderControl, fill: .surfaceHover))
        #expect(SettingsPopUpBody.roles(isEnabled: true, isPressed: true, isHovered: true)
            == .init(border: .borderControl, fill: .surfaceActive))
        #expect(SettingsPopUpBody.roles(isEnabled: false, isPressed: false, isHovered: true)
            == .init(border: .border, fill: nil))
    }

    /// `.popoverBordered` outlines an operable button; the selected tab's frame is a
    /// marker, not an outline, and stays `--border`.
    @Test @MainActor func aPopoverButtonIsOutlinedButTheSelectedTabOnlyFramed() {
        let bordered = PopoverBorderedButtonStyle.frame
        #expect(PopoverButtonBody.frameRole(bordered, isEnabled: true) == .borderControl)
        #expect(PopoverButtonBody.frameRole(bordered, isEnabled: false) == .border)
        let tab = PopoverIconButtonStyle(restingFill: .surfaceRaised, framed: true).frame
        #expect(PopoverButtonBody.frameRole(tab, isEnabled: true) == .border)
        #expect(PopoverButtonBody.frameRole(tab, isEnabled: false) == .border)
        let icon = PopoverIconButtonStyle().frame
        #expect(PopoverButtonBody.frameRole(icon, isEnabled: true) == nil)
    }

    @Test func theSearchFieldIsOutlinedByBorderControl() {
        #expect(SchemeSearchField.border(isEnabled: true) == .borderControl)
        #expect(SchemeSearchField.border(isEnabled: false) == .border)
    }
}

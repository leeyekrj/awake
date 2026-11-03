import ServiceManagement

import SwiftUI
import AppKit

struct PanelView: View {
    @ObservedObject var power: PowerController
    @Environment(\.colorScheme) var scheme
    var quit: () -> Void
    var toggleSettings: (() -> Void)? = nil
    var openSetup: (() -> Void)? = nil
    let amber = Color(red: 0.83, green: 0.48, blue: 0.16)
    let mint = Color(red: 0.16, green: 0.59, blue: 0.48)
    var panel: Color { scheme == .dark ? Color(red: 0.11, green: 0.12, blue: 0.13) : Color(red: 0.96, green: 0.96, blue: 0.97) }
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(amber)
                    .frame(width: 38, height: 38)
                    .background(amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Awake").font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("작업은 계속, 잠은 나중에.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let toggleSettings { toggleSettings() }
                    else { power.settingsOpen.toggle(); power.settingsReveal = power.settingsOpen ? 1 : 0 }
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary).frame(width: 30, height: 30)
                        .background(Color.primary.opacity(power.settingsOpen ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).help("설정").accessibilityLabel("설정")
            }
            VStack(spacing: 11) {
                coffeeCard
                lidCard
            }
            if let error = power.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(error).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { power.error = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).accessibilityLabel("오류 닫기")
                }.padding(10).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(spacing: 0) {
                settingsRevealSlot
            HStack(spacing: 5) {
                Image(systemName: power.onAC ? "bolt.fill" : "battery.75percent")
                    .foregroundStyle(power.onAC ? mint : .secondary)
                Text("\(power.battery)%").monospacedDigit()
                Text("·").opacity(0.5)
                Text(power.onAC ? "전원 연결" : "배터리 사용 중")
                Spacer()
                Button("종료", action: quit).buttonStyle(.plain).foregroundStyle(.secondary).help("앱이 켠 잠자기 방지를 해제하고 종료")
            }.font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .padding(18).frame(width: 356).background(panel)
    }
    var settingsRevealSlot: some View {
        settings.padding(.bottom, 16)
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: power.settingsExpandedHeight * power.settingsReveal, alignment: .top)
            .clipped()
            .opacity(min(1, power.settingsReveal * 2))
            .allowsHitTesting(power.settingsOpen && power.settingsReveal > 0.95)
            .accessibilityHidden(power.settingsReveal < 0.99)
    }
    @MainActor func measuredSettingsHeight() -> CGFloat {
        let measurement = NSHostingView(rootView: settings.padding(.bottom, 16).frame(width: 320).fixedSize(horizontal: false, vertical: true))
        return measurement.fittingSize.height
    }
    var coffeeCard: some View {
        card(tint: amber) {
            titleRow(icon: "cup.and.saucer.fill", title: "잠자기 방지", detail: "caffeinate", tint: amber, on: power.coffeeOn, busy: false, action: power.toggleCoffee)
                .disabled(power.durationEditor == .coffee)
            timerRow(active: power.coffeeOn, expiry: power.coffeeExpiry, offTitle: "맥을 깨어 있게", offSubtitle: "뚜껑을 열어둔 동안", tint: amber, minutes: power.coffeeOn ? power.coffeeSessionMinutes : power.coffeeMinutes)
            durationChoices(kind: .coffee, values: [(0,"무기한"),(60,"1시간"),(120,"2시간"),(240,"4시간")], tint: amber)
            if power.coffeeLinkedToLid {
                Text("뚜껑 모드와 함께 유지 중").font(.system(size: 10)).foregroundStyle(amber)
            }
            HStack {
                Image(systemName: power.screenOn ? "display" : "display.trianglebadge.exclamationmark").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("화면도 켜두기").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Toggle("화면도 켜두기", isOn: Binding(get: { power.screenOn }, set: power.updateScreen)).labelsHidden().toggleStyle(AwakeSwitch(tint: amber, label: "화면도 켜두기", compact: true))
            }
        }
    }
    var lidCard: some View {
        card(tint: mint) {
            titleRow(icon: "laptopcomputer", title: "뚜껑 닫고 계속", detail: "lidawake", tint: mint, on: power.lid != nil || power.sleepDisabled, busy: power.busy, action: power.toggleLid)
                .disabled(power.durationEditor == .lid)
            timerRow(active: power.lid != nil || power.sleepDisabled, expiry: power.lid?.expiry, offTitle: "닫아도 멈추지 않게", offSubtitle: "충전 중에도, 배터리로도", tint: mint, minutes: power.lidMinutes)
            durationChoices(kind: .lid, values: [(15,"15분"),(30,"30분"),(45,"45분"),(60,"1시간")], tint: mint)
            HStack(spacing: 5) {
                Image(systemName: power.watchdogReady ? "checkmark.shield.fill" : "exclamationmark.shield").foregroundStyle(power.watchdogReady ? mint : .orange)
                Text("배터리 \(power.lid?.floor ?? power.floor)% 아래에서 자동 해제")
                Spacer(minLength: 0)
            }.font(.system(size: 10.5)).foregroundStyle(.secondary)
            if power.lid?.scope == "-b" && power.onAC {
                Text("CLI에서 배터리 전용으로 켜짐 · 현재 전원 범위 밖").font(.system(size: 10)).foregroundStyle(.orange)
            } else if power.sleepDisabled && power.lid == nil {
                Text("만료 기록 없음 · 감시자가 자동 회수합니다").font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
    }
    func card<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(14)
            .background(scheme == .dark ? tint.opacity(0.08) : tint.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
            .background(scheme == .dark ? Color.white.opacity(0.035) : Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(tint.opacity(scheme == .dark ? 0.15 : 0.10), lineWidth: 0.8))
    }
    func titleRow(icon: String, title: String, detail: String, tint: Color, on: Bool, busy: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(tint)
                .frame(width: 27, height: 27).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small).frame(width: 34) }
            else {
                Toggle(title, isOn: Binding(get: { on }, set: { _ in action() }))
                    .labelsHidden().toggleStyle(AwakeSwitch(tint: tint, label: title))
            }
        }
    }
    func timerRow(active: Bool, expiry: Date?, offTitle: String, offSubtitle: String, tint: Color, minutes: Int) -> some View {
        CountdownRow(clock: power.displayClock, active: active, expiry: expiry,
                     offTitle: offTitle, offSubtitle: offSubtitle, tint: tint, minutes: minutes)
    }
    func durationChoices(kind: DurationKind, values: [(Int, String)], tint: Color) -> some View {
        let minutes = kind == .coffee ? power.coffeeMinutes : power.lidMinutes
        let custom = kind == .coffee ? power.coffeeCustomSelected : power.lidCustomSelected
        let editing = power.durationEditor == kind
        let locked = power.durationLocked(kind)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(values, id: \.0) { value, label in
                    durationChip(label, selected: !custom && !editing && minutes == value, tint: tint) {
                        power.selectPreset(value, kind: kind)
                    }.disabled(locked).help(locked ? "끄고 시간을 다시 선택해 주세요" : (value == 0 ? "직접 끌 때까지 유지" : "\(label) 동안 유지"))
                }
                durationChip("직접", selected: custom || editing, tint: tint) {
                    power.beginCustomDuration(kind)
                }.disabled(locked).help(locked ? "끄고 시간을 다시 선택해 주세요" : "원하는 시간을 분 단위로 입력")
            }
            if editing {
                HStack(spacing: 6) {
                    TextField("시간", text: $power.durationDraft)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                        .frame(width: 65)
                        .accessibilityLabel(kind == .coffee ? "caffeinate 직접 정할 시간" : "lidawake 직접 정할 시간")
                        .onSubmit { power.applyCustomDuration() }
                    Text("분").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    Button("취소") { power.durationEditor = nil; power.durationError = nil }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("적용") { power.applyCustomDuration() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tint).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
                if let error = power.durationError {
                    Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                } else if kind == .lid {
                    Text("최대 480분 · 8시간").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else if custom {
                Text("직접 정한 시간: \(minutes)분").font(.system(size: 10)).foregroundStyle(tint)
            }
        }
    }
    func durationChip(_ label: String, selected: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                .lineLimit(1).minimumScaleFactor(0.9)
                .foregroundStyle(selected ? tint : .secondary)
                .frame(maxWidth: .infinity).frame(height: 25)
                .background(selected ? tint.opacity(0.12) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
    var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: { openSetup?() }) {
                HStack {
                    Image(systemName: "wand.and.stars").foregroundStyle(mint)
                    Text("설치·핫스팟 설정").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("설치·핫스팟 설정")
            HStack {
                Text("배터리 보호 기준").font(.system(size: 11))
                Spacer()
                Picker("배터리 보호 기준", selection: $power.floor) {
                    Text("20%").tag(20); Text("30%").tag(30); Text("40%").tag(40)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 137).disabled(power.lid != nil)
            }
            Toggle("인터넷 끊기면 자동 복구", isOn: Binding(get: { power.hotspotEnabled }, set: power.setHotspotEnabled))
                .toggleStyle(.checkbox).font(.system(size: 11))
            Toggle("뚜껑 모드가 아닐 때도 감시", isOn: Binding(get: { power.netguardAlways }, set: power.setNetguardAlways))
                .toggleStyle(.checkbox).font(.system(size: 11)).padding(.leading, 18)
                .disabled(!power.hotspotEnabled)
            Text("40초 넘게 끊기면 내 핫스팟에 먼저 붙고, 안 되면 Wi-Fi를 껐다 켜서 저장된 와이파이로 다시 붙어요. 동의·로그인 화면이 뜨는 와이파이에서는 Wi-Fi를 건드리지 않아요.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let warning = power.hotspotWarning {
                Text(warning).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("lidawake 켤 때 caffeinate 자동 시작", isOn: Binding(get: { power.autoCoffeeWithLid }, set: power.setAutoCoffeeWithLid))
                .toggleStyle(.checkbox).font(.system(size: 11))
            Toggle("lidawake 종료 시 caffeinate도 끄기", isOn: Binding(get: { power.stopCoffeeWithLid }, set: power.setStopCoffeeWithLid))
                .toggleStyle(.checkbox).font(.system(size: 11))
                .disabled(!power.autoCoffeeWithLid)
            Text(power.stopCoffeeWithLid ? "lidawake만 켜면 함께 실행되고, 끝나면 함께 꺼져요." : "lidawake가 끝나도 caffeinate는 직접 끌 때까지 계속 켜져 있어요.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("로그인 시 실행", isOn: Binding(get: { power.loginEnabled }, set: power.toggleLogin)).toggleStyle(AwakeSwitch(tint: mint, label: "로그인 시 실행", showsLabel: true)).font(.system(size: 11))
            if power.loginNeedsApproval {
                Button("시스템 설정에서 로그인 항목 허용") { SMAppService.openSystemSettingsLoginItems() }.font(.system(size: 10))
            }
            Text("뚜껑 모드는 최대 8시간. 시간 만료·배터리 부족·재부팅 시 감시자가 자동 해제해요.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

// Only these small rows observe the second-by-second clock.
struct CountdownRow: View {
    @ObservedObject var clock: DisplayClock
    var active: Bool
    var expiry: Date?
    var offTitle: String
    var offSubtitle: String
    var tint: Color
    var minutes: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .lastTextBaseline) {
                if active {
                    Text(clock.countdown(expiry)).font(.system(size: 29, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(tint)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(expiry == nil ? "계속 유지" : "남은 시간").font(.system(size: 10, weight: .medium)).foregroundStyle(tint)
                        if let expiry { Text("\(expiry.formatted(date: .omitted, time: .shortened))에 해제").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(offTitle).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                        Text(offSubtitle).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }.frame(height: 37, alignment: .leading)
                    Spacer()
                    Text("OFF").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1.2).foregroundStyle(.tertiary)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.10))
                    Capsule().fill(tint.opacity(active ? 0.85 : 0.18)).frame(width: proxy.size.width * (active ? clock.progress(expiry, minutes: minutes) : 0.08))
                }
            }.frame(height: 3)
        }
    }
}

struct AwakeSwitch: ToggleStyle {
    var tint: Color
    var label: String
    var compact = false
    var showsLabel = false
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            if showsLabel {
                configuration.label
                Spacer(minLength: 0)
            }
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { configuration.isOn.toggle() }
            } label: {
                Capsule().fill(configuration.isOn ? tint : Color.primary.opacity(0.13))
                    .frame(width: compact ? 29 : 35, height: compact ? 17 : 21)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).shadow(color: .black.opacity(0.10), radius: 1, y: 1)
                            .frame(width: compact ? 13 : 17, height: compact ? 13 : 17).padding(2)
                    }
            }.buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityValue(configuration.isOn ? "켜짐" : "꺼짐")
        }
    }
}

private struct SettingsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 135
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

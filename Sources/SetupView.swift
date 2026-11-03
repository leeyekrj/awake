import SwiftUI

struct SetupView: View {
    @ObservedObject var setup: SetupController
    @ObservedObject var power: PowerController
    @Environment(\.colorScheme) var scheme
    let amber = Color(red: 0.83, green: 0.48, blue: 0.16)
    let mint = Color(red: 0.16, green: 0.59, blue: 0.48)
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 23)).foregroundStyle(amber)
                    .frame(width: 44, height: 44).background(amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Awake").font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("처음 한 번만 준비해요.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(min(3, setup.step.rawValue + 1)) / 3").font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(0..<3) { index in
                    Capsule().fill(index <= setup.step.rawValue ? mint : Color.primary.opacity(0.08)).frame(height: 4)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch setup.step {
                    case .welcome: welcome
                    case .permission: permission
                    case .hotspot: hotspot
                    case .done: done
                    }
                    if let error = setup.error {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 2)
            }.scrollIndicators(.automatic)
            HStack {
                if setup.step != .welcome {
                    Button("이전", action: setup.goBack)
                        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(setup.busy)
                        .accessibilityLabel("이전 단계")
                }
                if setup.step != .done {
                    Button("나중에", action: setup.later)
                        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(setup.busy)
                        .padding(.leading, setup.step == .welcome ? 0 : 16)
                }
                Spacer()
                if setup.busy { ProgressView().controlSize(.small) }
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent).tint(mint).controlSize(.large)
                    .disabled(setup.busy || (setup.step == .permission && !setup.helperReady && !setup.allowPasswordless))
            }
        }.padding(28).frame(width: 500, height: 640)
            .background(scheme == .dark ? Color(red: 0.11, green: 0.12, blue: 0.13) : Color(red: 0.96, green: 0.96, blue: 0.97))
    }
    func heading(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 24, weight: .semibold, design: .rounded))
            Text(description).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }
    func feature(_ icon: String, _ title: String, _ description: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(color).frame(width: 32, height: 32)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(description).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
    }
    var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("작업이 끊기지 않도록", "세 가지 기능을 메뉴 막대에서 편하게 사용하세요.")
            feature("cup.and.saucer.fill", "잠자기 방지", "caffeinate로 맥을 깨어 있게 유지해요.", amber)
            feature("laptopcomputer", "뚜껑 닫고 계속", "lidawake와 자동 해제 감시자를 함께 설치해요.", mint)
            feature("wifi", "핫스팟 자동 연결", "인터넷이 끊기면 내 휴대폰 핫스팟으로 연결을 시도해요.", mint)
            Text("설정 시작을 누르면 앱을 응용 프로그램 폴더에 설치해요. 필요하면 macOS가 관리자 승인을 요청해요.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    var permission: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("뚜껑 모드 준비", "뚜껑을 닫아도 작업을 계속하려면 macOS 관리자 승인이 필요해요.")
            if setup.helperReady {
                feature("checkmark.shield.fill", "이미 준비되어 있어요", "기존 lidawake와 실행 권한을 그대로 사용할게요.", mint)
            } else {
                feature("checkmark.shield", "자동 해제까지 함께", "시간 만료·배터리 부족·재부팅 시 뚜껑 모드를 해제하는 감시자를 설치해요.", mint)
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("lidawake 제어를 관리자 암호 없이 허용", isOn: $setup.allowPasswordless)
                        .toggleStyle(.checkbox).font(.system(size: 13, weight: .medium))
                    Text("승인 후에는 메뉴 막대에서 바로 켜고 끌 수 있어요. 권한은 Awake의 lidawake 전용 도구에만 적용돼요.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }.padding(16).background(mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                Text("관리자 암호는 macOS 인증 창에서 입력해요. Awake는 암호를 저장하지 않아요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    var hotspot: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("내 핫스팟 연결", "lidawake 중 인터넷이 끊겼을 때 연결할 휴대폰 핫스팟을 정해 주세요.")
            Toggle("핫스팟 자동 연결 사용", isOn: $setup.hotspotEnabled).toggleStyle(.checkbox).font(.system(size: 13, weight: .medium))
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("핫스팟 이름").font(.system(size: 12, weight: .medium))
                    TextField("휴대폰의 Wi-Fi 이름", text: $setup.ssid).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Wi-Fi 암호").font(.system(size: 12, weight: .medium))
                    SecureField(setup.hasSavedPassword ? "비워두면 저장된 암호를 유지해요" : "이미 맥에 저장되어 있다면 생략 가능", text: $setup.password).textFieldStyle(.roundedBorder)
                    Text("입력한 암호는 이 맥의 키체인에 저장돼요.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button("핫스팟 연결 확인", action: setup.testConnection).disabled(setup.ssid.trimmingCharacters(in: .whitespaces).isEmpty || setup.busy)
                if let result = setup.connectionResult { Text(result).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
                .disabled(!setup.hotspotEnabled)
            Text("휴대폰에서 개인용 핫스팟을 켜 두세요. 지금 사용하지 않으려면 위 체크를 해제하고 완료할 수 있어요.")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }
    var done: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("준비됐어요", "이제 메뉴 막대의 커피잔을 눌러 사용하세요.")
            feature("checkmark.circle.fill", "잠자기 방지", "필요한 시간만큼 켜 두세요.", amber)
            feature("checkmark.shield.fill", "뚜껑 모드 준비 완료", "관리자 암호 없이 켜고 끌 수 있어요.", mint)
            feature(setup.hotspotEnabled ? "wifi" : "wifi.slash", setup.hotspotEnabled ? "핫스팟 연결 준비 완료" : "핫스팟 자동 연결 꺼짐", setup.hotspotEnabled ? setup.ssid : "설정에서 언제든 등록할 수 있어요.", mint)
            Text("caffeinate 자동 시작과 종료 방식은 Awake 설정에서 선택할 수 있어요.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    var primaryTitle: String {
        switch setup.step {
        case .welcome: return "설정 시작"
        case .permission: return setup.helperReady ? "계속" : "승인하고 설치"
        case .hotspot: return "설정 완료"
        case .done: return "Awake 사용하기"
        }
    }
    func primaryAction() {
        switch setup.step {
        case .welcome: setup.begin()
        case .permission: if setup.helperReady { setup.step = .hotspot } else { setup.installHelper() }
        case .hotspot: setup.finish()
        case .done: setup.requestClose?()
        }
    }
}

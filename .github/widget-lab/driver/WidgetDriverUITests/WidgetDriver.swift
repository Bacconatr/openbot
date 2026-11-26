import XCTest

/// Drives SpringBoard to put one app's widget on the Home Screen.
///
/// xcodebuild passes `TEST_RUNNER_<NAME>` from its environment to the test as `<NAME>`:
/// - `WIDGET_SEARCH`: text typed into the widget gallery search, such as the app name.
/// - `WIDGET_SIZE`: `small`, `medium` or `large`.
/// - `LAB_OUT_DIR`, `LAB_LABEL`: host folder and file prefix for step screenshots, trees and the log.
///
/// Measured on iOS 27.2: long-press an icon, Edit Home Screen, Edit, Add Widget, search, tap the
/// app's row. Its sheet pages sideways through previews whose accessibility value names the size
/// ("Widget, Small"), above a " Add Widget" button whose label starts with an icon character.
final class WidgetDriver: XCTestCase {
  enum Size: String {
    case small, medium, large
  }

  private struct DriverError: LocalizedError {
    let errorDescription: String?
  }

  private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
  private let env = ProcessInfo.processInfo.environment
  private var outDir = URL(fileURLWithPath: NSTemporaryDirectory())
  private var label = "run"
  private var step = 0

  override func setUpWithError() throws {
    continueAfterFailure = false
    if let dir = env["LAB_OUT_DIR"], !dir.isEmpty { outDir = URL(fileURLWithPath: dir) }
    if let value = env["LAB_LABEL"], !value.isEmpty { label = value }
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    log("WIDGET_SEARCH=\(env["WIDGET_SEARCH"] ?? "-") WIDGET_SIZE=\(env["WIDGET_SIZE"] ?? "-") screen=\(springboard.frame)")
  }

  func testAddWidget() throws {
    guard let search = env["WIDGET_SEARCH"], !search.isEmpty else { throw failure("WIDGET_SEARCH is not set") }
    guard let size = Size(rawValue: env["WIDGET_SIZE"] ?? "") else {
      throw failure("WIDGET_SIZE must be small, medium or large")
    }
    goHome()
    snap("home")
    try enterEditMode()
    try openGallery()
    try openApp(named: search)
    try showPreview(of: size)
    try addWidget()
    leaveEditMode()
    snap("done")
    let onHome = springboard.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS[c] %@", search)).allElementsBoundByIndex
    log("home screen elements naming \(search): \(onHome.map { "'\($0.label)' value '\($0.value ?? "")' \($0.frame)" })")
  }

  // MARK: Steps

  private func goHome() {
    XCUIDevice.shared.press(.home)
    sleep(2)
    dismissAlerts()
  }

  private func isEditing() -> Bool {
    control("Done", timeout: 0) != nil || control("Edit", timeout: 0) != nil
  }

  private func enterEditMode() throws {
    if let icon = homeIcon() {
      log("long-pressing the \(icon.label) icon")
      icon.press(forDuration: 1.2)
      if let edit = control("Edit Home Screen", timeout: 3) {
        edit.tap()
      } else {
        log("the icon menu has no Edit Home Screen; controls: \(controlLabels())")
      }
      if waitUntil(4, isEditing) {
        snap("edit-mode")
        return
      }
      XCUIDevice.shared.press(.home)
      sleep(1)
    }
    log("long-pressing an empty spot of the page")
    springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).press(forDuration: 2.5)
    if waitUntil(4, isEditing) {
      snap("edit-mode")
      return
    }
    throw failure("could not put the Home Screen in edit mode; controls: \(controlLabels())")
  }

  private func openGallery() throws {
    var add = control("Add Widget", timeout: 1)
    if add == nil, let edit = control("Edit", timeout: 3) {
      edit.tap()
      add = control("Add Widget", timeout: 4)
    }
    guard let add else { throw failure("found no Add Widget control; controls: \(controlLabels())") }
    snap("edit-menu")
    add.tap()
    guard springboard.searchFields.firstMatch.waitForExistence(timeout: 8) else {
      throw failure("the widget gallery did not open")
    }
    sleep(1)
    snap("gallery")
    log("gallery apps: \(springboard.cells.allElementsBoundByIndex.map(\.label))")
  }

  private func openApp(named name: String) throws {
    let field = springboard.searchFields.firstMatch
    field.tap()
    sleep(1)
    field.typeText(name)
    sleep(2)
    snap("search")
    let fieldBottom = field.frame.maxY
    let keyboard = springboard.keyboards.firstMatch
    let keyboardFrame = keyboard.exists ? keyboard.frame : CGRect.null
    // A result row: a cell or text labeled with the name, below the field and above the keyboard.
    let named = NSPredicate(format: "label ==[c] %@ OR label BEGINSWITH[c] %@", name, name + ",")
    var hit: XCUIElement?
    _ = waitUntil(8) {
      for query in [springboard.cells, springboard.staticTexts, springboard.buttons] {
        for item in query.matching(named).allElementsBoundByIndex {
          let frame = item.frame
          if frame.minY >= fieldBottom && !frame.intersects(keyboardFrame) && item.isHittable {
            hit = item
            return true
          }
        }
      }
      return false
    }
    guard let hit else { throw failure("the gallery search found nothing named \(name)") }
    log("tapping result '\(hit.label)' \(hit.frame)")
    hit.tap()
    guard addWidgetButton().waitForExistence(timeout: 8) else {
      throw failure("tapping the \(name) result did not open its widgets")
    }
    sleep(1)
  }

  /// Pages through the app's previews until the one in view has the size.
  private func showPreview(of size: Size) throws {
    let screen = springboard.frame
    for page in 0..<12 {
      let previews = springboard.buttons.matching(NSPredicate(format: "value BEGINSWITH[c] 'Widget'"))
        .allElementsBoundByIndex
      let inView = previews.first { $0.frame.minX >= 0 && $0.frame.maxX <= screen.width && $0.frame.width > 0 }
      let value = inView.map { "\($0.value ?? "")" } ?? ""
      log("gallery page \(page): in view '\(inView?.label ?? "-")' value '\(value)' frame \(inView?.frame ?? .null); all \(previews.map { "\($0.value ?? "")" })")
      snap("page-\(page)")
      guard let inView else { throw failure("no widget preview in view on gallery page \(page)") }
      if value.range(of: size.rawValue, options: .caseInsensitive) != nil { return }
      let y = inView.frame.midY
      let origin = springboard.coordinate(withNormalizedOffset: .zero)
      origin.withOffset(CGVector(dx: screen.width * 0.85, dy: y))
        .press(
          forDuration: 0.01, thenDragTo: origin.withOffset(CGVector(dx: screen.width * 0.15, dy: y)),
          withVelocity: .fast, thenHoldForDuration: 0)
      sleep(1)
    }
    throw failure("no \(size.rawValue) widget in the first 12 gallery pages")
  }

  private func addWidget() throws {
    let add = addWidgetButton()
    guard add.waitForExistence(timeout: 3) else { throw failure("the Add Widget button is gone") }
    add.tap()
    guard waitUntil(8, { !self.addWidgetButton().exists }) else {
      throw failure("the gallery did not close after Add Widget")
    }
    sleep(2)
    snap("added")
  }

  private func leaveEditMode() {
    if let done = control("Done", timeout: 3) {
      done.tap()
    } else {
      log("no Done button; pressing Home")
      XCUIDevice.shared.press(.home)
    }
    sleep(2)
    if isEditing() {
      XCUIDevice.shared.press(.home)
      sleep(1)
    }
  }

  // MARK: Elements

  /// The sheet's button, labeled " Add Widget" on iOS 27.2: an icon character, then the text.
  private func addWidgetButton() -> XCUIElement {
    springboard.buttons.matching(NSPredicate(format: "label ENDSWITH 'Add Widget'")).firstMatch
  }

  /// A hittable button, menu item or other element labeled `label`, polled until `timeout`.
  private func control(_ label: String, timeout: TimeInterval) -> XCUIElement? {
    let predicate = NSPredicate(format: "label == %@ OR identifier == %@", label, label)
    let candidates = [springboard.buttons, springboard.menuItems, springboard.otherElements]
      .map { $0.matching(predicate).firstMatch }
    var found: XCUIElement?
    _ = waitUntil(timeout) {
      found = candidates.first { $0.exists && $0.isHittable }
      return found != nil
    }
    return found
  }

  private func homeIcon() -> XCUIElement? {
    for name in ["Settings", "Calendar", "Photos", "Safari"] {
      let icon = springboard.icons.matching(NSPredicate(format: "label == %@", name)).firstMatch
      if icon.exists && icon.isHittable { return icon }
    }
    let icon = springboard.icons.firstMatch
    return icon.exists && icon.isHittable ? icon : nil
  }

  private func dismissAlerts() {
    for _ in 0..<3 {
      let alert = springboard.alerts.firstMatch
      guard alert.waitForExistence(timeout: 1) else { return }
      let buttons = alert.buttons.allElementsBoundByIndex
      log("dismissing alert '\(alert.label)' with buttons \(buttons.map(\.label))")
      let preferred = ["Allow", "OK", "Continue", "Don't Allow", "Not Now", "Cancel"]
      let button = preferred.lazy.map { alert.buttons[$0] }.first { $0.exists } ?? buttons.first
      button?.tap()
      sleep(1)
    }
  }

  private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      usleep(250_000)
    }
    return condition()
  }

  private func controlLabels() -> [String] {
    springboard.buttons.allElementsBoundByIndex.map(\.label)
  }

  // MARK: Evidence

  private func log(_ message: String) {
    print("[widget-driver] \(message)")
    let url = outDir.appendingPathComponent("\(label)-driver.log")
    let data = Data((message + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: url)
    }
  }

  /// A screenshot and the accessibility tree, as files for the artifact and as test attachments.
  private func snap(_ name: String) {
    step += 1
    let base = String(format: "%@-%02d-%@", label, step, name)
    let shot = XCUIScreen.main.screenshot()
    try? shot.pngRepresentation.write(to: outDir.appendingPathComponent(base + ".png"))
    try? springboard.debugDescription.write(
      to: outDir.appendingPathComponent(base + ".txt"), atomically: true, encoding: .utf8)
    let attachment = XCTAttachment(screenshot: shot)
    attachment.name = base
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func failure(_ message: String) -> Error {
    snap("failed")
    log("FAILED: \(message)")
    return DriverError(errorDescription: message)
  }
}

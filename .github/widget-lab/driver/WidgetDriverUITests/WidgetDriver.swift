import XCTest

/// Drives SpringBoard to put one app's widget on the Home Screen.
///
/// xcodebuild passes `TEST_RUNNER_<NAME>` from its environment to the test as `<NAME>`:
/// - `WIDGET_SEARCH`: text typed into the widget gallery search, such as the app name.
/// - `WIDGET_SIZE`: `small`, `medium` or `large`.
/// - `WIDGET_PAGE`: optional gallery page to add (0-based). Without it the driver reads the size of
///   each page's preview and stops at the first page of `WIDGET_SIZE`.
/// - `LAB_OUT_DIR`, `LAB_LABEL`: host folder and file prefix for step screenshots, trees and the log.
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
    log(
      "WIDGET_SEARCH=\(env["WIDGET_SEARCH"] ?? "-") WIDGET_SIZE=\(env["WIDGET_SIZE"] ?? "-") "
        + "WIDGET_PAGE=\(env["WIDGET_PAGE"] ?? "-") screen=\(springboard.frame)")
  }

  func testAddWidget() throws {
    guard let search = env["WIDGET_SEARCH"], !search.isEmpty else { throw failure("WIDGET_SEARCH is not set") }
    guard let size = Size(rawValue: env["WIDGET_SIZE"] ?? "") else {
      throw failure("WIDGET_SIZE must be small, medium or large")
    }
    let forcedPage = env["WIDGET_PAGE"].flatMap { Int($0) }
    goHome()
    snap("home")
    try enterEditMode()
    try openGallery()
    try openApp(named: search)
    try showPage(for: size, forcedPage: forcedPage)
    try addWidget()
    leaveEditMode()
    snap("done")
    let onHome = elements().filter { $0.label.localizedCaseInsensitiveContains(search) }
    log("home screen elements naming \(search): \(onHome.map(describe))")
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
    let lowered = name.lowercased()
    let hits = elements()
      .filter { item in
        item.elementType != .searchField && item.frame.width > 0 && item.frame.height > 0
          && item.frame.minY >= fieldBottom && !item.frame.intersects(keyboardFrame)
          && (item.label.lowercased() == lowered || item.label.lowercased().hasPrefix(lowered + ","))
      }
      .sorted { $0.frame.minY < $1.frame.minY }
    log("search results for \(name): \(hits.map(describe))")
    guard let hit = hits.first else { throw failure("the gallery search found nothing named \(name)") }
    tap(hit)
    guard control("Add Widget", timeout: 8) != nil else {
      throw failure("tapping the \(name) result did not open its widgets")
    }
    sleep(1)
  }

  private func showPage(for size: Size, forcedPage: Int?) throws {
    var previous: String?
    for page in 0..<10 {
      let all = elements()
      let preview = currentPreview(in: all)
      let family = preview.map(classify)
      let indicator = all.first { $0.elementType == .pageIndicator }
      let signature = "\(preview.map(describe) ?? "-") \(indicator.map(describe) ?? "-")"
      log("gallery page \(page): family \(family?.rawValue ?? "unknown"); preview \(preview.map(describe) ?? "none"); indicator \(indicator.map(describe) ?? "none")")
      snap("page-\(page)")
      if let forcedPage {
        if page == forcedPage { return }
      } else if family == size {
        return
      }
      if signature == previous { throw failure("the gallery stopped at page \(page) without a \(size.rawValue) widget") }
      previous = signature
      swipeToNextPage(at: preview?.frame)
    }
    throw failure("no \(size.rawValue) widget in the first 10 gallery pages")
  }

  private func addWidget() throws {
    guard let add = control("Add Widget", timeout: 3) else { throw failure("the Add Widget button is gone") }
    add.tap()
    guard waitUntil(8, { !self.springboard.searchFields.firstMatch.exists }) else {
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

  // MARK: Gallery pages

  /// The largest element that fits on screen and has a widget's proportions: the visible preview.
  private func currentPreview(in all: [XCUIElementSnapshot]) -> XCUIElementSnapshot? {
    let screen = springboard.frame
    let add = all.first { $0.elementType == .button && $0.label == "Add Widget" }?.frame
    return all
      .filter { item in
        let frame = item.frame
        return frame.minX >= 1 && frame.maxX <= screen.width - 1
          && frame.width >= 0.3 * screen.width && frame.width <= 0.97 * screen.width
          && frame.height >= 0.3 * screen.width && frame.height <= 0.7 * screen.height
          && (add == nil || frame.maxY <= add!.minY)
      }
      .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
  }

  private func classify(_ preview: XCUIElementSnapshot) -> Size {
    let frame = preview.frame
    if frame.width / frame.height > 1.5 { return .medium }
    return frame.width < 0.6 * springboard.frame.width ? .small : .large
  }

  private func swipeToNextPage(at frame: CGRect?) {
    let screen = springboard.frame
    let y = frame?.midY ?? screen.height * 0.45
    let origin = springboard.coordinate(withNormalizedOffset: .zero)
    let start = origin.withOffset(CGVector(dx: screen.width * 0.85, dy: y))
    let end = origin.withOffset(CGVector(dx: screen.width * 0.15, dy: y))
    start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    sleep(1)
  }

  // MARK: Elements

  private func elements() -> [XCUIElementSnapshot] {
    guard let root = try? springboard.snapshot() else { return [] }
    var result: [XCUIElementSnapshot] = []
    var pending: [XCUIElementSnapshot] = [root]
    while let item = pending.popLast() {
      result.append(item)
      pending.append(contentsOf: item.children.reversed())
    }
    return result
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

  private func tap(_ item: XCUIElementSnapshot) {
    springboard.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: item.frame.midX, dy: item.frame.midY))
      .tap()
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
    elements().filter { $0.elementType == .button || $0.elementType == .menuItem }.map(\.label)
  }

  private func describe(_ item: XCUIElementSnapshot) -> String {
    let value = item.value.map { " value='\($0)'" } ?? ""
    return "[type \(item.elementType.rawValue) '\(item.label)' id='\(item.identifier)'\(value) \(item.frame)]"
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

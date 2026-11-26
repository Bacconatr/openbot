import XCTest

/// Drives SpringBoard for the widget lab. Each test is one scene the shell runs by name.
///
/// xcodebuild passes `TEST_RUNNER_<NAME>` from its environment to the test as `<NAME>`:
/// - `WIDGET_SEARCH`: text typed into the widget gallery search, such as the app name.
/// - `WIDGET_SIZE`: `small`, `medium` or `large` (testAddWidget).
/// - `WIDGET_ROW`: the row text to tap on the Home Screen widget (testTapRow).
/// - `APP_BUNDLE`: the bundle id that a tap must bring to the foreground (testTapRow).
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
  /// Hosts the Lock Screen editor since iOS 16.
  private let posterboard = XCUIApplication(bundleIdentifier: "com.apple.PosterBoard")
  private let env = ProcessInfo.processInfo.environment
  private var outDir = URL(fileURLWithPath: NSTemporaryDirectory())
  private var label = "run"
  private var step = 0
  private let started = Date()

  override func setUpWithError() throws {
    continueAfterFailure = false
    if let dir = env["LAB_OUT_DIR"], !dir.isEmpty { outDir = URL(fileURLWithPath: dir) }
    if let value = env["LAB_LABEL"], !value.isEmpty { label = value }
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    log("start \(name) at \(Int(started.timeIntervalSince1970 * 1000)) ms WIDGET_SEARCH=\(env["WIDGET_SEARCH"] ?? "-") WIDGET_SIZE=\(env["WIDGET_SIZE"] ?? "-") screen=\(springboard.frame)")
  }

  // MARK: Tests

  func testAddWidget() throws {
    let search = try searchText()
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
  }

  /// Settings, Home Screen & App Library, App Library Only: apps installed later, such as this
  /// runner, stay off the Home Screen.
  func testNewAppsToAppLibrary() throws {
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    settings.activate()
    sleep(3)
    snap("settings")
    let row = settings.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH 'Home Screen'")).firstMatch
    for _ in 0..<6 where !(row.exists && row.isHittable) {
      settings.swipeUp()
      sleep(1)
    }
    guard row.exists && row.isHittable else {
      throw failure("Settings has no Home Screen row; texts: \(settings.staticTexts.allElementsBoundByIndex.map(\.label))")
    }
    row.tap()
    sleep(2)
    snap("home-screen-settings")
    let option = settings.descendants(matching: .any)
      .matching(NSPredicate(format: "label == 'App Library Only'")).firstMatch
    guard option.waitForExistence(timeout: 5) else {
      throw failure("no App Library Only option; texts: \(settings.staticTexts.allElementsBoundByIndex.map(\.label))")
    }
    option.tap()
    sleep(1)
    snap("app-library-only")
    log("App Library Only: selected \(option.isSelected) value '\(option.value ?? "")'")
    settings.terminate()
  }

  /// Home Screen, Edit, Customize, Tinted: widgets then render in the accented mode.
  func testTintHomeScreen() throws {
    goHome()
    try enterEditMode()
    var customize = control("Customize", timeout: 1)
    if customize == nil, let edit = control("Edit", timeout: 3) {
      edit.tap()
      customize = control("Customize", timeout: 4)
    }
    guard let customize else { throw failure("found no Customize control; controls: \(controlLabels())") }
    snap("edit-menu")
    customize.tap()
    sleep(2)
    snap("customize")
    log("customize controls: \(controlLabels())")
    guard let tinted = control("Tinted", timeout: 5, types: [.button, .other, .cell, .staticText]) else {
      throw failure("the Customize sheet has no Tinted option; controls: \(controlLabels())")
    }
    tinted.tap()
    sleep(2)
    snap("tinted")
    // The sheet closes on a tap above it.
    springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
    sleep(2)
    leaveEditMode()
    snap("done")
  }

  /// Taps the row text on the app's Home Screen widget and expects the app in the foreground.
  func testTapRow() throws {
    guard let row = env["WIDGET_ROW"], !row.isEmpty else { throw failure("WIDGET_ROW is not set") }
    guard let bundle = env["APP_BUNDLE"], !bundle.isEmpty else { throw failure("APP_BUNDLE is not set") }
    goHome()
    snap("home")
    let matching = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", row))
    var target: XCUIElement?
    _ = waitUntil(8) {
      let hits = matching.allElementsBoundByIndex.filter { $0.exists && $0.frame.width > 0 }
      // The smallest element that holds the text is the row, not the whole widget.
      target = hits.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
      return target != nil
    }
    guard let target else { throw failure("no element on the Home Screen holds '\(row)'") }
    log("tapping '\(target.label)' (\(target.elementType.rawValue)) at \(target.frame)")
    target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    let app = XCUIApplication(bundleIdentifier: bundle)
    guard app.wait(for: .runningForeground, timeout: 15) else {
      throw failure("\(bundle) did not come to the foreground; its state is \(app.state.rawValue)")
    }
    log("\(bundle) is in the foreground")
    sleep(4)
    snap("opened")
  }

  /// Lock Screen editor: adds the app's circular and rectangular widgets below the clock and its
  /// inline widget above it, then leaves the device on the Lock Screen.
  func testLockScreenWidgets() throws {
    let search = try searchText()
    goHome()
    lockAndWake()
    snap("locked")
    log("lock screen: springboard \(springboard.state.rawValue) posterboard \(posterboard.state.rawValue)")
    springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 2.0)
    sleep(2)
    snap("long-pressed")
    guard let customize = control("Customize", timeout: 6) else {
      throw failure("long-pressing the Lock Screen showed no Customize; controls: \(controlLabels())")
    }
    customize.tap()
    sleep(2)
    snap("customize")
    if let lock = control("Lock Screen", timeout: 4, types: [.button, .other, .cell, .image, .staticText]) {
      lock.tap()
      sleep(2)
    } else {
      log("no Lock Screen choice; assuming the editor opened directly")
    }
    snap("editor")

    // Below the clock: circular and rectangular.
    let widgetsSlot = control("Add Widgets", timeout: 6, types: [.button, .other])
      ?? control("Widgets", timeout: 2, types: [.button, .other])
    guard let widgetsSlot else { throw failure("the Lock Screen editor shows no Add Widgets slot; controls: \(controlLabels())") }
    widgetsSlot.tap()
    sleep(2)
    snap("widget-picker")
    try openLockApp(named: search)
    snap("app-widgets")
    let added = addLockPreviews(max: 2)
    log("added \(added) accessory widgets below the clock")
    closeSheet()
    snap("below-clock")

    // Above the clock: inline, from the date line.
    let date = control("Date", timeout: 1, types: [.button, .other])
      ?? firstElement(NSPredicate(format: "label CONTAINS[c] %@", weekday()), types: [.button, .other, .staticText])
    if let date {
      log("tapping the date '\(date.label)'")
      date.tap()
      sleep(2)
      snap("inline-picker")
      do {
        try openLockApp(named: search)
        snap("inline-app")
        log("added \(addLockPreviews(max: 1)) inline widget")
      } catch {
        log("inline: \(error.localizedDescription)")
      }
      closeSheet()
    } else {
      log("found no date control above the clock; controls: \(controlLabels())")
    }
    snap("edited")

    guard let done = control("Done", timeout: 4, types: [.button]) else {
      throw failure("the Lock Screen editor has no Done; controls: \(controlLabels())")
    }
    done.tap()
    sleep(3)
    snap("after-done")
    // Back in the wallpaper switcher, a tap on the current wallpaper returns to the Lock Screen.
    if control("Customize", timeout: 2) != nil {
      springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
      sleep(3)
    }
    snap("lock-screen")
    if added == 0 { throw failure("no accessory widget was added below the clock") }
  }

  // MARK: Steps

  private func searchText() throws -> String {
    guard let search = env["WIDGET_SEARCH"], !search.isEmpty else { throw failure("WIDGET_SEARCH is not set") }
    return search
  }

  private func goHome() {
    XCUIDevice.shared.press(.home)
    sleep(2)
    dismissAlerts()
  }

  /// XCUIDevice has no public lock button; WebDriverAgent calls the same private selector.
  private func lockAndWake() {
    let press = NSSelectorFromString("pressLockButton")
    guard XCUIDevice.shared.responds(to: press) else {
      log("XCUIDevice has no pressLockButton")
      return
    }
    XCUIDevice.shared.perform(press)
    sleep(2)
    XCUIDevice.shared.perform(press)
    sleep(3)
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

  /// In the Lock Screen widget picker: finds the app by search field or by scrolling, and opens it.
  private func openLockApp(named name: String) throws {
    let named = NSPredicate(format: "label ==[c] %@ OR label BEGINSWITH[c] %@", name, name + ",")
    let types: [XCUIElement.ElementType] = [.cell, .button, .staticText, .other]
    for app in [springboard, posterboard] where isUp(app) && app.searchFields.firstMatch.exists {
      let field = app.searchFields.firstMatch
      log("typing into the picker search field of \(app == springboard ? "SpringBoard" : "PosterBoard")")
      field.tap()
      sleep(1)
      field.typeText(name)
      sleep(2)
      break
    }
    var hit: XCUIElement?
    for attempt in 0..<8 {
      hit = firstElement(named, types: types, hittable: true)
      if hit != nil { break }
      log("picker attempt \(attempt): no \(name); texts \(staticTexts().prefix(40))")
      // Scroll the picker list up.
      let origin = springboard.coordinate(withNormalizedOffset: .zero)
      let screen = springboard.frame
      origin.withOffset(CGVector(dx: screen.width / 2, dy: screen.height * 0.85))
        .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: screen.width / 2, dy: screen.height * 0.6)))
      sleep(1)
    }
    guard let hit else { throw failure("the Lock Screen picker lists no \(name)") }
    log("tapping picker app '\(hit.label)' \(hit.frame)")
    hit.tap()
    sleep(2)
  }

  /// Taps up to `max` of the app's widget previews in the open picker, logging what each was.
  private func addLockPreviews(max: Int) -> Int {
    var added = 0
    for app in [springboard, posterboard] where isUp(app) {
      let previews = app.descendants(matching: .any)
        .matching(NSPredicate(format: "value BEGINSWITH[c] 'Widget' OR label CONTAINS[c] 'Agents'"))
        .allElementsBoundByIndex
        .filter { $0.exists && $0.isHittable && $0.frame.width > 0 }
      log("picker previews in \(app == springboard ? "SpringBoard" : "PosterBoard"): \(previews.map { "'\($0.label)' value '\($0.value ?? "")' \($0.frame)" })")
      for preview in previews where added < max {
        log("tapping preview '\(preview.label)' value '\(preview.value ?? "")'")
        preview.tap()
        added += 1
        sleep(2)
        snap("preview-\(added)")
      }
      if added > 0 { break }
    }
    return added
  }

  private func closeSheet() {
    if let close = control("Close", timeout: 2, types: [.button]) {
      close.tap()
    } else {
      log("no Close button; tapping above the sheet")
      springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
    }
    sleep(2)
  }

  private func weekday() -> String {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US")
    format.dateFormat = "EEEE"
    return format.string(from: Date())
  }

  // MARK: Elements

  /// The sheet's button, labeled " Add Widget" on iOS 27.2: an icon character, then the text.
  private func addWidgetButton() -> XCUIElement {
    springboard.buttons.matching(NSPredicate(format: "label ENDSWITH 'Add Widget'")).firstMatch
  }

  /// A hittable element labeled `label` in SpringBoard or PosterBoard, polled until `timeout`.
  private func control(
    _ label: String, timeout: TimeInterval, types: [XCUIElement.ElementType] = [.button, .menuItem, .other]
  ) -> XCUIElement? {
    let predicate = NSPredicate(format: "label == %@ OR identifier == %@", label, label)
    var found: XCUIElement?
    _ = waitUntil(timeout) {
      found = firstElement(predicate, types: types, hittable: true)
      return found != nil
    }
    return found
  }

  /// Queries on an app that is not running hang or fail, and PosterBoard runs only for the editor.
  private func isUp(_ app: XCUIApplication) -> Bool {
    app.state == .runningForeground || app.state == .runningBackground
  }

  private func firstElement(
    _ predicate: NSPredicate, types: [XCUIElement.ElementType], hittable: Bool = true
  ) -> XCUIElement? {
    for app in [springboard, posterboard] where isUp(app) {
      for type in types {
        let item = app.descendants(matching: type).matching(predicate).firstMatch
        if item.exists && (!hittable || item.isHittable) { return item }
      }
    }
    return nil
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
    [springboard, posterboard].filter(isUp)
      .flatMap { $0.buttons.allElementsBoundByIndex.map(\.label) }
  }

  private func staticTexts() -> [String] {
    [springboard, posterboard].filter(isUp)
      .flatMap { $0.staticTexts.allElementsBoundByIndex.map(\.label) }
  }

  // MARK: Evidence

  private func log(_ message: String) {
    let line = String(format: "[%6.1fs] %@", Date().timeIntervalSince(started), message)
    print("[widget-driver] \(line)")
    let url = outDir.appendingPathComponent("\(label)-driver.log")
    let data = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: url)
    }
  }

  /// A screenshot and the accessibility trees, as files for the artifact and as test attachments.
  private func snap(_ name: String) {
    step += 1
    let base = String(format: "%@-%02d-%@", label, step, name)
    log("snap \(base)")
    let shot = XCUIScreen.main.screenshot()
    try? shot.pngRepresentation.write(to: outDir.appendingPathComponent(base + ".png"))
    var trees = springboard.debugDescription
    if isUp(posterboard) { trees += "\n\n=== PosterBoard\n" + posterboard.debugDescription }
    try? trees.write(to: outDir.appendingPathComponent(base + ".txt"), atomically: true, encoding: .utf8)
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

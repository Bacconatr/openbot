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

  /// Lock Screen editor: adds the app's accessory widgets below the clock and its inline widget
  /// above it, then leaves the device on the Lock Screen.
  ///
  /// Measured on iOS 27.2 (run 45896636629): long-press, Customize opens the editor directly. Its
  /// slots are SpringBoard buttons "Add Widget" (below the clock) and "Calendar, Date, Top Widget",
  /// repeated for each wallpaper page, so only the one inside the screen counts.
  func testLockScreenWidgets() throws {
    let search = try searchText()
    goHome()
    lockAndWake()
    snap("locked")
    springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 2.0)
    sleep(2)
    snap("long-pressed")
    guard let customize = spot(timeout: 6, { $0.label == "Customize" }) else {
      throw failure("long-pressing the Lock Screen showed no Customize; elements: \(labeled())")
    }
    tap(customize)
    sleep(3)
    if let choice = spot(timeout: 2, { $0.label == "Lock Screen" }) {
      tap(choice)
      sleep(2)
    }
    snap("editor")

    // Below the clock.
    guard let slot = spot(timeout: 6, { $0.label == "Add Widget" && $0.frame.midY > self.screen.height * 0.5 }) else {
      throw failure("the Lock Screen editor shows no Add Widget slot; elements: \(labeled())")
    }
    tap(slot)
    sleep(3)
    snap("widget-picker")
    log("picker elements: \(labeled())")
    try openLockApp(named: search)
    snap("app-widgets")
    log("app widgets: \(labeled())")
    let added = addLockPreviews(max: 2)
    log("added \(added) accessory widgets below the clock")
    closeSheet()
    snap("below-clock")

    // Above the clock: the inline widget replaces the date line's calendar.
    if let date = spot(timeout: 3, { $0.label.contains("Top Widget") }) {
      tap(date)
      sleep(3)
      log("inline widget added: \(addInline(named: search))")
      closeSheet()
    } else {
      log("found no Top Widget slot; elements: \(labeled())")
    }
    snap("edited")

    guard let done = spot(timeout: 4, { $0.label == "Done" }) else {
      throw failure("the Lock Screen editor has no Done; elements: \(labeled())")
    }
    tap(done)
    sleep(3)
    snap("after-done")
    log("after Done: \(labeled())")
    // Back in the wallpaper switcher, a tap on the current wallpaper returns to the Lock Screen.
    if spot(timeout: 2, { $0.label == "Customize" }) != nil {
      springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
      sleep(3)
    }
    snap("lock-screen")
    log("lock screen: \(labeled())")
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
    log("gallery: \(labeled())")
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
      sleep(UInt32(env["PAGE_HOLD"] ?? "") ?? 1)
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
    let isApp: (Spot) -> Bool = {
      ($0.label.caseInsensitiveCompare(name) == .orderedSame || $0.label.lowercased().hasPrefix(name.lowercased() + ","))
        && $0.type != .searchField
    }
    if let field = spot(timeout: 1, { $0.type == .searchField }) {
      log("typing into the picker search field '\(field.label)'")
      tap(field)
      sleep(1)
      springboard.typeText(name)
      sleep(2)
      snap("picker-search")
    }
    var hit: Spot?
    for attempt in 0..<8 {
      hit = spot(timeout: 1, isApp)
      if hit != nil { break }
      log("picker attempt \(attempt): no \(name)")
      let origin = springboard.coordinate(withNormalizedOffset: .zero)
      origin.withOffset(CGVector(dx: screen.width / 2, dy: screen.height * 0.85))
        .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: screen.width / 2, dy: screen.height * 0.6)))
      sleep(1)
    }
    guard let hit else { throw failure("the Lock Screen picker lists no \(name); elements: \(labeled())") }
    log("tapping picker app '\(hit.label)' \(hit.frame)")
    tap(hit)
    sleep(2)
  }

  /// Taps up to `max` of the app's widget previews, the elements that newly appeared under the app.
  private func addLockPreviews(max: Int) -> Int {
    // Run 45899436059: each preview is a button valued "Widget, Circular" or "Widget, Rectangular".
    let previews = spots { $0.value.hasPrefix("Widget") && $0.frame.minY > self.screen.height * 0.35 }
    log("previews: \(previews.map { "'\($0.label)' value '\($0.value)' \($0.type.rawValue) \($0.frame)" })")
    var added = 0
    var seen: [CGRect] = []
    for preview in previews where added < max && !seen.contains(where: { $0.intersects(preview.frame) }) {
      seen.append(preview.frame)
      log("tapping preview '\(preview.label)' value '\(preview.value)'")
      tap(preview)
      added += 1
      sleep(2)
      snap("preview-\(added)")
    }
    return added
  }

  /// Closes the picker with its close button, else by dragging its grabber down. A tap above the
  /// sheet lands on the date line and reopens the inline picker (run 45899436059).
  private func closeSheet() {
    if let close = spot(timeout: 2, { $0.label.caseInsensitiveCompare("close") == .orderedSame && $0.type == .button }) {
      tap(close)
    } else if let grabber = spot(timeout: 1, { $0.label == "Sheet Grabber" }) {
      log("no close button; dragging the sheet grabber down")
      drag(from: grabber, toY: screen.height * 0.98)
    } else {
      log("no close button or grabber; tapping above the sheet")
      springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
    }
    sleep(2)
  }

  /// The inline picker lists apps down a sheet whose lower rows start offscreen: expand it, then
  /// tap the first entry under the app's heading.
  private func addInline(named name: String) -> Bool {
    if let grabber = spot(timeout: 2, { $0.label == "Sheet Grabber" }) {
      drag(from: grabber, toY: screen.height * 0.1)
      sleep(2)
    }
    for attempt in 0..<5 {
      snap("inline-\(attempt)")
      log("inline picker: \(labeled())")
      if let heading = spot(timeout: 1, { $0.label == name && $0.type == .staticText }) {
        let options = spots {
          $0.frame.minY > heading.frame.maxY - 2 && $0.frame.minY < heading.frame.maxY + 120
            && ($0.value.hasPrefix("Widget") || $0.label.hasPrefix(name + ",") || $0.label.contains("waiting"))
        }
        if let option = options.first {
          log("tapping inline option '\(option.label)' value '\(option.value)' \(option.frame)")
          tap(option)
          sleep(2)
          snap("inline-added")
          return true
        }
      }
      let origin = springboard.coordinate(withNormalizedOffset: .zero)
      origin.withOffset(CGVector(dx: screen.width / 2, dy: screen.height * 0.85))
        .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: screen.width / 2, dy: screen.height * 0.55)))
      sleep(1)
    }
    return false
  }

  private func drag(from spot: Spot, toY y: CGFloat) {
    let origin = springboard.coordinate(withNormalizedOffset: .zero)
    origin.withOffset(CGVector(dx: spot.frame.midX, dy: spot.frame.midY))
      .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: spot.frame.midX, dy: y)))
  }

  // MARK: Snapshots

  /// One labeled element from an atomic snapshot of SpringBoard. Element queries on SpringBoard fail
  /// with "Failed to get matching snapshot" when a sheet changes mid-query; a snapshot cannot.
  private struct Spot {
    let label: String
    let value: String
    let type: XCUIElement.ElementType
    let frame: CGRect
  }

  private var screen: CGRect { springboard.frame }

  /// Every labeled element inside the screen that matches, in tree order.
  private func spots(_ match: (Spot) -> Bool) -> [Spot] {
    guard let root = try? springboard.snapshot() else { return [] }
    let bounds = screen
    var found: [Spot] = []
    var stack: [XCUIElementSnapshot] = [root]
    while let node = stack.popLast() {
      stack.append(contentsOf: node.children.reversed())
      let item = Spot(
        label: node.label, value: node.value.map { "\($0)" } ?? "", type: node.elementType, frame: node.frame)
      guard !item.label.isEmpty || !item.value.isEmpty else { continue }
      guard item.frame.width > 0, item.frame.height > 0, bounds.contains(CGPoint(x: item.frame.midX, y: item.frame.midY))
      else { continue }
      if match(item) { found.append(item) }
    }
    return found
  }

  private func spot(timeout: TimeInterval, _ match: (Spot) -> Bool) -> Spot? {
    var hit: Spot?
    _ = waitUntil(timeout) {
      hit = spots(match).first
      return hit != nil
    }
    return hit
  }

  private func tap(_ spot: Spot) {
    springboard.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: spot.frame.midX, dy: spot.frame.midY)).tap()
  }

  /// The labeled elements on screen, for the log.
  private func labeled() -> [String] {
    spots { _ in true }.map { "\($0.type.rawValue):'\($0.label)'\($0.value.isEmpty ? "" : "=\($0.value)")" }
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
    spots { $0.type == .button }.map(\.label)
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

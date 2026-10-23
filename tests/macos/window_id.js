ObjC.import('CoreGraphics');
function run(argv) {
  const pid = parseInt(argv[0]);
  const list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll, 0)));
  for (const w of list) {
    if (w.kCGWindowOwnerPID === pid && w.kCGWindowLayer === 0 && w.kCGWindowName === 'profane') return String(w.kCGWindowNumber);
  }
  return '';
}

import 'dart:io';

import 'package:curated_score/scratch_space.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a session folder stays while its app runs; leftovers of apps that are gone are swept', () async {
    final mine = ScratchSpace.folder('job');
    File('${mine.path}/a.flac').writeAsStringSync('x');

    // Another app, still running: a child process holds its session's lock.
    final other = Directory('${ScratchSpace.root.path}/session-other-live').path;
    Directory(other).createSync(recursive: true);
    final locker = await Process.start('python3', [
      '-c',
      'import fcntl,time,sys; f=open(sys.argv[1],"w"); fcntl.lockf(f, fcntl.LOCK_EX); print("locked", flush=True); time.sleep(30)',
      '$other/.lock',
    ]);
    await locker.stdout.first;
    // A crashed app's session (nobody holds its lock) and a loose leftover from older versions.
    final crashed = Directory('${ScratchSpace.root.path}/session-crashed')..createSync(recursive: true);
    File('${crashed.path}/.lock').writeAsStringSync('');
    final loose = Directory('${ScratchSpace.root.path}/media-123')..createSync(recursive: true);

    ScratchSpace.sweep(keep: ScratchSpace.session.path);
    expect(mine.existsSync(), isTrue);
    expect(Directory(other).existsSync(), isTrue, reason: 'its app still runs');
    expect(crashed.existsSync(), isFalse);
    expect(loose.existsSync(), isFalse);

    locker.kill();
    await locker.exitCode;
    ScratchSpace.sweep(keep: ScratchSpace.session.path);
    expect(Directory(other).existsSync(), isFalse, reason: 'its app has quit');

    ScratchSpace.release(mine);
    expect(mine.existsSync(), isFalse);
    final session = ScratchSpace.session;
    ScratchSpace.close();
    expect(session.existsSync(), isFalse);
  }, skip: Platform.isWindows ? 'uses a POSIX child process to hold the lock' : false);
}

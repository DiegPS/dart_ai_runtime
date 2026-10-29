import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final mode = arguments.single;
  if (mode == 'exit') {
    stderr.writeln('Fixture failed before readiness.');
    exitCode = 17;
    return;
  }
  if (mode == 'invalid-utf8') {
    stdout.add([0xff]);
    await stdout.flush();
  }
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  stdout.writeln('Unrelated startup message.');
  stdout.writeln('http://127.0.0.1:0');
  stdout.writeln('http://127.0.0.1:65536');
  final output = mode == 'stderr' ? stderr : stdout;
  output.writeln('Fixture listening at http://localhost:${socket.port}');
  await output.flush();
  await for (final command
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (command == 'exit') break;
    stdout.writeln('Fixture received: $command');
    stderr.writeln('Fixture diagnostic.');
    await stdout.flush();
    await stderr.flush();
  }
  await socket.close();
}

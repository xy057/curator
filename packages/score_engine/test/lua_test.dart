import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/src/lua.dart';

/// What [code] returns, each value as Lua writes it.
List<String> run(String code, {Lua? lua, int? steps}) {
  lua ??= Lua();
  return [for (final v in lua.run(code, chunk: 'test.lua', steps: steps)) lua.tostring(v)];
}

String fails(String code, {int? steps}) {
  try {
    run(code, steps: steps);
  } on LuaError catch (e) {
    return e.message;
  }
  fail('no error from: $code');
}

void main() {
  test('Lua: values and operators, closures, loops, tables and metatables, strings, math, errors, limits, and the host', () {
    // Values, operators and numbers of one kind.
    {
      expect(run('return 1 + 2, 7 / 2, 4 / 2, 7 // 2, -7 // 2, 7 % 3, -7 % 3, 7 % -3, 2 ^ 10, 10 // 0.3'), ['3', '3.5', '2', '3', '-4', '1', '2', '-2', '1024', '33']);
      expect(run('return 1 == 1.0, "1" == 1, 0.1 + 0.2 == 0.3, 3 | 4, 6 & 3, 5 ~ 1, ~0, 1 << 4, 256 >> 4'), ['true', 'false', 'false', '7', '2', '4', '4294967295', '16', '16']);
      expect(run('return "a" .. "b" .. 1 .. 2.5, #"hello", not nil, nil == false, 1 < 2, "a" < "b", "10" + 5, 10 .. ""'), ['ab12.5', '5', 'true', 'false', 'true', 'true', '15', '10']);
      expect(run('return 1 and 2, nil and 1, false or "x", nil or false, 1 or error("never")'), ['2', 'nil', 'x', 'false', '1']);
      expect(run('return 0x10, 1e3, .5, 3 % math.huge, math.maxinteger, 2^53 == 2^53 + 1, 1/0, -1/0, 0/0 ~= 0/0'), ['16', '1000', '0.5', '3', '9007199254740991', 'true', 'inf', '-inf', 'true']);
      expect(run(r'''return "tab\tnew\\ \65\x41\u{48}\z   end", [[long
string]], [==[a]]b]==]'''), ['tab\tnew\\ AAHend', 'long\nstring', 'a]]b']);
    }

    // Locals, closures, varargs and several values.
    {
      expect(run('''
        local function counter()
          local n = 0
          return function() n = n + 1 return n end
        end
        local a, b = counter(), counter()
        a() a()
        return a(), b()
      '''), ['3', '1']);
      // Each turn of a loop has a variable of its own.
      expect(run('''
        local fs = {}
        for i = 1, 3 do fs[i] = function() return i end end
        local out = {}
        for _, f in ipairs(fs) do out[#out + 1] = f() end
        return table.concat(out, ",")
      '''), ['1,2,3']);
      expect(run('''
        local function f(...) return select("#", ...), ... end
        local function g() return 1, 2, 3 end
        local t = {g(), g()}
        local a, b, c, d = g()
        return #t, (g()), f(g()), f(nil, nil), a, b, c, d
      '''), ['4', '1', '3', '2', '1', '2', '3', 'nil']);
      expect(run('local a, b, c = 1 a, b = b, a return a, b, c'), ['nil', '1', 'nil']);
      expect(run('local t = {1, nil, 3} return #t, t[3], #{n = 1}, #{nil, nil}'), ['3', '3', '0', '0']);
      expect(run('local x <const> = 5 return x'), ['5']);
      expect(fails('local x <const> = 5 x = 6'), contains("attempt to assign to const variable 'x'"));
    }

    // Control flow, goto and loops.
    {
      expect(run('''
        local out = {}
        for i = 1, 10 do
          if i % 2 == 0 then goto continue end
          if i > 7 then break end
          out[#out + 1] = i
          ::continue::
        end
        for i = 3, 1, -1 do out[#out + 1] = i end
        for i = 1, 2, 0.5 do out[#out + 1] = i end
        local n = 0
        while true do n = n + 1 if n == 4 then break end end
        repeat local done = n > 5 n = n + 1 until done
        return table.concat(out, " "), n
      '''), ['1 3 5 7 3 2 1 1 1.5 2', '7']);
      expect(run('''
        local t = {10, 20, 30, x = 1, y = 2}
        local keys, sum = {}, 0
        for k, v in pairs(t) do keys[#keys + 1] = tostring(k) sum = sum + v end
        for k in pairs(t) do if k == "x" then t[k] = nil end end
        return table.concat(keys, ","), sum, t.x, next({}), next({5})
      '''), ['1,2,3,x,y', '63', 'nil', 'nil', '1', '5']);
      expect(fails('for i = 1, 10, 0 do end'), "test.lua:1: 'for' step is zero");
    }

    // Tables, metatables and methods.
    {
      expect(run('''
        local Point = {}
        Point.__index = Point
        function Point.new(x, y) return setmetatable({x = x, y = y}, Point) end
        function Point:len() return math.sqrt(self.x ^ 2 + self.y ^ 2) end
        Point.__add = function(a, b) return Point.new(a.x + b.x, a.y + b.y) end
        Point.__eq = function(a, b) return a.x == b.x and a.y == b.y end
        Point.__tostring = function(p) return "(" .. p.x .. "," .. p.y .. ")" end
        Point.__lt = function(a, b) return a:len() < b:len() end
        Point.__len = function() return 2 end
        Point.__call = function(p, k) return p[k] end
        Point.__concat = function(a, b) return tostring(a) .. tostring(b) end
        local p = Point.new(3, 4) + Point.new(0, 0)
        local defaults = setmetatable({}, {__index = function(_, k) return k .. "!" end, __newindex = function(t, k, v) rawset(t, k, v * 2) end})
        defaults.n = 4
        return p:len(), tostring(p), p == Point.new(3, 4), p ~= p, Point.new(1, 1) < p, #p, p("x"), p .. p, defaults.missing, defaults.n,
          getmetatable(p) == Point, rawequal(p, Point.new(3, 4)), getmetatable("s").__index == string
      '''), ['5', '(3,4)', 'true', 'false', 'true', '2', '3', '(3,4)(3,4)', 'missing!', '8', 'true', 'false', 'true']);
      expect(run('''
        local t = {}
        t[1] = "a" t[3] = "c" t[2] = "b"          -- 3 joins the list once 2 is there
        table.insert(t, "d") table.insert(t, 1, "z")
        local removed = table.remove(t, 2)
        local last = table.remove(t)
        table.sort(t, function(a, b) return a > b end)
        local packed = table.pack(1, nil, 3)
        return #t, table.concat(t, ""), removed, last, packed.n, table.unpack({1, 2, 3}, 2), select(-1, 1, 2, 3)
      '''), ['3', 'zcb', 'a', 'd', '3', '2', '3']);
      expect(run('local t = {5, 2, 8, 1} table.sort(t) return table.concat(t, ","), table.concat(table.move({1, 2, 3}, 1, 3, 2), ",")'), ['1,2,5,8', '1,1,2,3']);
    }

    // The string library.
    {
      expect(run(r'''
        local s = "Hello, World"
        return s:len(), s:sub(1, 5), s:sub(-5), s:upper(), s:lower(), s:rep(2, "|"), s:reverse(), s:byte(1), string.char(72, 105),
          s:find("World"), s:find("o", 6), s:find("l+"), s:find(".", 1, true), s:match("(%a+), (%a+)"), s:match("^%s*$"), ("  trim  "):match("^%s*(.-)%s*$")
      '''), ['12', 'Hello', 'World', 'HELLO, WORLD', 'hello, world', 'Hello, World|Hello, World', 'dlroW ,olleH', '72', 'Hi', '8', '9', '3', 'nil', 'Hello', 'nil', 'trim']);
      expect(run(r'''
        local words = {}
        for w in ("one two  three"):gmatch("%a+") do words[#words + 1] = w end
        local pairs_ = {}
        for k, v in ("a=1, b=2"):gmatch("(%w+)=(%w+)") do pairs_[#pairs_ + 1] = k .. v end
        return table.concat(words, "/"), table.concat(pairs_, "/"),
          ("hello world"):gsub("o", "0"), ("hello"):gsub("", "-"), ("abc"):gsub("%w", "%0%0"), ("a b"):gsub("(%w) (%w)", "%2 %1"),
          ("x = 1"):gsub("%w+", {x = "y"}), ("3 4"):gsub("%d", function(d) return d * 2 end), ("f(a(b)c)d"):match("%b()"),
          ("THE (quick) fox"):find("%f[%a]%a+%f[%A]"), ("key: value"):match("^(%w+):%s*(.+)$")
      '''), ['one/two/three', 'a1/b2', 'hell0 w0rld', '-h-e-l-l-o-', 'aabbcc', 'b a', 'y = 1', '6 8', '(a(b)c)', '1', 'key', 'value']);
      // (A tie rounds away from zero, as Dart's own formatting does: 1.25 is 1.3, where C says 1.2.)
      expect(run(r'''
        return string.format("%d %5d|%-5d|%05d %+d %x %X %o %c", 42, 42, 42, 42, 42, 255, 255, 8, 65),
          string.format("%.2f %10.3f|%-8.1f|%e %.0f %g %g %g %g", 3.14159, 2.5, 1.25, 12345.678, 2.5, 0.1, 1e20, 100000, 1e-5),
          string.format("%s %10s|%-10s|%.2s %q %%", "a", "b", "c", "long", 'q"uote'), string.format("%5.1f%%", 12.345), string.format("%s %s", 1, true)
      '''), ['42    42|42   |00042 +42 ff FF 10 A', '3.14      2.500|1.3     |1.234568e+04 3 0.1 1e+20 100000 1e-05', 'a          b|c         |lo "q\\"uote" %', ' 12.3%', '1 true']);
      expect(run('return tostring(12), tostring(1.5), tostring(1e100), tonumber("0x1F"), tonumber(" 12.5 "), tonumber("z", 36), tonumber("nope"), tonumber("1e2"), utf8.len("héllo"), utf8.char(233)'),
          ['12', '1.5', '1e+100', '31', '12.5', '35', 'nil', '100', '5', 'é']);
    }

    // Math, and the same random numbers every time.
    {
      expect(run('return math.floor(2.7), math.ceil(2.1), math.floor(-2.5), math.max(1, 9, 3), math.min(4, 2), math.abs(-3), math.fmod(7, 3), math.fmod(-7, 3), math.tointeger(3.0), math.tointeger(3.5), math.type(1), math.type(1.5), math.type("1")'),
          ['2', '3', '-3', '9', '2', '3', '1', '-1', '3', 'nil', 'integer', 'float', 'nil']);
      expect(run('return math.sqrt(16), math.pi > 3.14, math.huge > 1e308, math.sin(0), math.cos(0), math.atan(1, 1) * 4 == math.pi, math.log(8, 2), math.exp(0), math.modf(3.7)'),
          ['4', 'true', 'true', '0', '1', 'true', '3', '1', '3', '0.7000000000000002']);
      final first = run('math.randomseed(7) return math.random(100), math.random(100), math.random(5, 6), math.random() < 1');
      expect(run('math.randomseed(7) return math.random(100), math.random(100), math.random(5, 6), math.random() < 1'), first);
      expect(first.last, 'true');
    }

    // Errors say where, and pcall.
    {
      expect(fails('local t = nil\nreturn t.x'), "test.lua:2: attempt to index a nil value (local 't')");
      expect(fails('return undefined.field'), "test.lua:1: attempt to index a nil value (global 'undefined')");
      expect(fails('local t = {}\nt.a.b = 1'), "test.lua:2: attempt to index a nil value (field 'a')");
      expect(fails('local t = {}\n\nt:nope()'), "test.lua:3: attempt to call a nil value (method 'nope')");
      expect(fails('nothing()'), "test.lua:1: attempt to call a nil value (global 'nothing')");
      expect(fails('return 1 + {}'), 'test.lua:1: attempt to perform arithmetic on a table value');
      expect(fails('local s = "x" return s + 1'), "test.lua:1: attempt to perform arithmetic on a string value (local 's')");
      expect(fails('return 1 < "2"'), 'test.lua:1: attempt to compare number with string');
      expect(fails('return {} .. "x"'), 'test.lua:1: attempt to concatenate a table value');
      expect(fails('return #5'), 'test.lua:1: attempt to get length of a number value');
      expect(fails('error("boom")'), 'test.lua:1: boom');
      expect(fails('local function f() error("deep", 2) end\n\nf()'), 'test.lua:3: deep');
      expect(fails('error("as is", 0)'), 'as is');
      expect(fails('error({code = 1})'), startsWith('table: 0x'));
      expect(fails('assert(false, "nope")'), 'nope');
      expect(fails('assert(nil)'), 'assertion failed!');
      expect(fails('table.insert(nil, 1)'), "test.lua:1: bad argument #1 to 'insert' (table expected, got nil)");
      expect(fails('("x"):rep()'), "test.lua:1: bad argument #2 to 'rep' (number expected, got no value)");
      expect(fails('local t = {}\nt[nil] = 1'), 'test.lua:2: table index is nil');
      expect(fails('x = = 1'), "test.lua:1: unexpected symbol near '='");
      expect(fails('if x then\n\n'), "test.lua:3: 'end' expected (to close 'if' at line 1) near '<eof>'");
      expect(fails('local s = "open'), 'test.lua:1: unfinished string');
      expect(fails('break'), contains('break outside a loop'));
      expect(fails('goto nowhere'), contains("no visible label 'nowhere'"));
      expect(fails('coroutine.wrap(print)'), contains("coroutines aren't available"));
      expect(run('''
        local ok, e = pcall(function() local t = nil return t.x end)
        local ok2, e2 = pcall(error, {code = 7})
        local ok3, a, b = pcall(function(...) return ... end, 1, 2)
        local ok4, e4 = xpcall(function() error("x", 0) end, function(m) return "handled " .. m end)
        return ok, e, ok2, e2.code, ok3, a, b, ok4, e4, select("#", pcall(error))
      '''), ['false', "test.lua:1: attempt to index a nil value (local 't')", 'false', '7', 'true', '1', '2', 'false', 'handled x', '2']);
      // An error knows its file and line, and the calls it came through.
      try {
        run('local function inner()\n  error("bad")\nend\nlocal function outer()\n  inner()\nend\nouter()');
        fail('no error');
      } on LuaError catch (e) {
        expect((e.chunk, e.line), ('test.lua', 2));
        expect(e.trace, ['test.lua:2', 'test.lua:5', 'test.lua:7']);
      }
    }

    // A script that would never end is stopped, pcall or not.
    {
      expect(fails('while true do end', steps: 10000), contains('ran too long'));
      expect(fails('while true do pcall(function() while true do end end) end', steps: 10000), contains('ran too long'));
      expect(fails('local function f() return f() end f()'), contains('stack overflow'));
      expect(fails('local function f() return 1 + f() end return pcall(f)'), contains('stack overflow'));
      expect(fails('local s = "x" while true do s = s .. s end'), contains('grew too long'));
      expect(fails('return ("x"):rep(1e9)'), contains('grew too long'));
      expect(fails('return ("a"):rep(40):match(("a*"):rep(40) .. "b")', steps: 100000), contains('ran too long'));
      // After it, the same world runs again.
      final lua = Lua();
      expect(() => lua.run('while true do end', steps: 1000), throwsA(isA<LuaLimit>()));
      expect(lua.run('return 1 + 1'), [2]);
    }

    // The host gives functions and modules, and reads what print writes.
    {
      final printed = <String>[];
      final lua = Lua(print: printed.add)
        ..register('twice', (a) => [a.number(0, 'twice') * 2])
        ..source = (name) => name == 'util' ? (chunk: 'util.lua', code: 'local M = {} function M.inc(x) return x + 1 end return M') : null;
      expect(lua.run('local util = require("util") print("a", 1, nil) return util.inc(twice(4)), require("util") == util'), [9, true]);
      expect(printed, ['a\t1\tnil']);
      expect(() => lua.run('require("missing")', chunk: 'main.lua'), throwsA(isA<LuaError>().having((e) => e.message, 'message', "main.lua:1: module 'missing' not found")));
      expect(() => lua.run('twice("x")', chunk: 'main.lua'),
          throwsA(isA<LuaError>().having((e) => e.message, 'message', "main.lua:1: bad argument #1 to 'twice' (number expected, got string)")));
      // What the host throws is Lua's error, where it was called.
      lua.register('broken', (a) => throw StateError('host'));
      expect(lua.run('local ok, e = pcall(broken) return ok, e'), [false, 'Bad state: host']);
      final f = lua.run('return function(a, b) return a + b end')[0] as LuaFunction;
      expect(lua.call(f, [2, 3]), [5]);
      expect((f as LuaClosure).parameters, ['a', 'b']);
    }
  });
}

// The JSON Attacca writes and the little of it it reads: one object a line each way.
#pragma once

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>
#include <vector>

namespace attacca {

// Writes one JSON value, commas placed as values are added.
class JsonWriter {
public:
    JsonWriter& object () { value (); out_ += '{'; first_.push_back (true); return *this; }
    JsonWriter& endObject () { out_ += '}'; first_.pop_back (); return *this; }
    JsonWriter& array () { value (); out_ += '['; first_.push_back (true); return *this; }
    JsonWriter& endArray () { out_ += ']'; first_.pop_back (); return *this; }

    JsonWriter& key (const char* name)
    {
        comma ();
        quoted (name);
        out_ += ':';
        afterKey_ = true;
        return *this;
    }

    JsonWriter& string (const std::string& text) { value (); quoted (text); return *this; }
    JsonWriter& boolean (bool b) { value (); out_ += b ? "true" : "false"; return *this; }
    JsonWriter& null () { value (); out_ += "null"; return *this; }
    // A value written already (another writer's text).
    JsonWriter& raw (const std::string& json) { value (); out_ += json; return *this; }

    // A number as precise as a double holds, its decimal mark a point whatever locale the DAW set
    // (printf writes the locale's: "0,5" where the mark is a comma, which isn't JSON); NaN and
    // infinities, which JSON has no word for, as null.
    JsonWriter& number (double d)
    {
        if (!std::isfinite (d))
            return null ();
        value ();
        char buffer[40];
        std::snprintf (buffer, sizeof buffer, "%.17g", d);
        // Digits, signs and the exponent are the same in every locale: anything else is the mark.
        bool marked = false;
        for (const char* c = buffer; *c; ++c)
        {
            if ((*c >= '0' && *c <= '9') || *c == '-' || *c == '+' || *c == 'e' || *c == 'E')
                out_ += *c;
            else if (!marked)
                out_ += '.', marked = true;
        }
        return *this;
    }

    // key and value in one.
    JsonWriter& field (const char* name, const std::string& text) { return key (name).string (text); }
    JsonWriter& field (const char* name, const char* text) { return key (name).string (text ? text : ""); }
    JsonWriter& field (const char* name, double d) { return key (name).number (d); }
    JsonWriter& field (const char* name, bool b) { return key (name).boolean (b); }

    const std::string& text () const { return out_; }

private:
    void comma ()
    {
        if (first_.empty ())
            return;
        if (!first_.back ())
            out_ += ',';
        first_.back () = false;
    }

    // A value in an array takes a comma; one after a key doesn't.
    void value ()
    {
        if (afterKey_)
            afterKey_ = false;
        else
            comma ();
    }

    void quoted (const std::string& text)
    {
        out_ += '"';
        for (unsigned char c : text)
        {
            switch (c)
            {
                case '"': out_ += "\\\""; break;
                case '\\': out_ += "\\\\"; break;
                case '\n': out_ += "\\n"; break;
                case '\r': out_ += "\\r"; break;
                case '\t': out_ += "\\t"; break;
                default:
                    if (c < 0x20)
                    {
                        char buffer[8];
                        std::snprintf (buffer, sizeof buffer, "\\u%04x", c);
                        out_ += buffer;
                    }
                    else
                    {
                        out_ += static_cast<char> (c);
                    }
            }
        }
        out_ += '"';
    }

    std::string out_;
    std::vector<bool> first_;
    bool afterKey_ { false };
};

// Reads the top level of one JSON object: each name's string, number or true / false as text
// (a string unescaped). Objects and arrays inside it are passed over. False when [text] isn't
// one object.
inline bool readFlatObject (const std::string& text, std::map<std::string, std::string>& out)
{
    size_t i = 0;
    const size_t n = text.size ();
    auto space = [&] { while (i < n && (text[i] == ' ' || text[i] == '\t' || text[i] == '\r' || text[i] == '\n')) ++i; };
    auto str = [&] (std::string& s) -> bool {
        if (i >= n || text[i] != '"')
            return false;
        ++i;
        while (i < n && text[i] != '"')
        {
            char c = text[i++];
            if (c != '\\')
            {
                s += c;
                continue;
            }
            if (i >= n)
                return false;
            c = text[i++];
            switch (c)
            {
                case 'n': s += '\n'; break;
                case 't': s += '\t'; break;
                case 'r': s += '\r'; break;
                case 'b': s += '\b'; break;
                case 'f': s += '\f'; break;
                case 'u':
                {
                    if (i + 4 > n)
                        return false;
                    unsigned code = static_cast<unsigned> (std::strtoul (text.substr (i, 4).c_str (), nullptr, 16));
                    i += 4;
                    // UTF-8 of one code unit (paths Curator sends are its own, so no surrogate pairs are needed).
                    if (code < 0x80)
                        s += static_cast<char> (code);
                    else if (code < 0x800)
                    {
                        s += static_cast<char> (0xc0 | (code >> 6));
                        s += static_cast<char> (0x80 | (code & 0x3f));
                    }
                    else
                    {
                        s += static_cast<char> (0xe0 | (code >> 12));
                        s += static_cast<char> (0x80 | ((code >> 6) & 0x3f));
                        s += static_cast<char> (0x80 | (code & 0x3f));
                    }
                    break;
                }
                default: s += c;
            }
        }
        if (i >= n)
            return false;
        ++i;
        return true;
    };
    // Passes over an object or array, strings inside it included.
    auto skipNested = [&] () -> bool {
        int depth = 0;
        while (i < n)
        {
            const char c = text[i];
            if (c == '"')
            {
                std::string ignored;
                if (!str (ignored))
                    return false;
                continue;
            }
            ++i;
            if (c == '{' || c == '[')
                ++depth;
            else if (c == '}' || c == ']')
            {
                if (--depth == 0)
                    return true;
            }
        }
        return false;
    };

    space ();
    if (i >= n || text[i] != '{')
        return false;
    ++i;
    space ();
    if (i < n && text[i] == '}')
        return true;
    while (i < n)
    {
        space ();
        std::string name;
        if (!str (name))
            return false;
        space ();
        if (i >= n || text[i] != ':')
            return false;
        ++i;
        space ();
        if (i >= n)
            return false;
        std::string value;
        if (text[i] == '"')
        {
            if (!str (value))
                return false;
            out[name] = value;
        }
        else if (text[i] == '{' || text[i] == '[')
        {
            if (!skipNested ())
                return false;
        }
        else
        {
            const size_t start = i;
            while (i < n && text[i] != ',' && text[i] != '}' && text[i] != ' ' && text[i] != '\n')
                ++i;
            out[name] = text.substr (start, i - start);
        }
        space ();
        if (i < n && text[i] == ',')
        {
            ++i;
            continue;
        }
        if (i < n && text[i] == '}')
            return true;
        return false;
    }
    return false;
}

}  // namespace attacca

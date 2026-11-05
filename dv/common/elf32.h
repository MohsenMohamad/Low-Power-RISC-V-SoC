// Minimal ELF32 little-endian loader: PT_LOAD segments and symbol lookup.
#pragma once
#include <cstdint>
#include <cstring>
#include <fstream>
#include <functional>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

struct Elf32Image {
  struct Segment { uint32_t paddr; std::vector<uint8_t> bytes; uint32_t memsz; };
  uint32_t entry = 0;
  std::vector<Segment> segments;
  std::map<std::string, uint32_t> symbols;

  static Elf32Image load(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("cannot open ELF " + path);
    std::vector<uint8_t> d((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    auto rd16 = [&](size_t o) { return uint32_t(d.at(o)) | uint32_t(d.at(o + 1)) << 8; };
    auto rd32 = [&](size_t o) { return rd16(o) | rd16(o + 2) << 16; };
    if (d.size() < 52 || memcmp(d.data(), "\x7f" "ELF", 4) != 0 || d[4] != 1 || d[5] != 1)
      throw std::runtime_error("not an ELF32 LE file: " + path);
    Elf32Image img;
    img.entry = rd32(24);
    uint32_t phoff = rd32(28), shoff = rd32(32);
    uint32_t phentsize = rd16(42), phnum = rd16(44), shentsize = rd16(46), shnum = rd16(48);
    for (uint32_t i = 0; i < phnum; i++) {
      size_t p = phoff + i * phentsize;
      if (rd32(p) != 1) continue;  // PT_LOAD
      uint32_t off = rd32(p + 4), paddr = rd32(p + 12), filesz = rd32(p + 16), memsz = rd32(p + 20);
      if (memsz == 0) continue;
      Segment s{paddr, std::vector<uint8_t>(d.begin() + off, d.begin() + off + filesz), memsz};
      img.segments.push_back(std::move(s));
    }
    // Symbols
    for (uint32_t i = 0; i < shnum; i++) {
      size_t sh = shoff + i * shentsize;
      if (rd32(sh + 4) != 2) continue;  // SHT_SYMTAB
      uint32_t off = rd32(sh + 16), size = rd32(sh + 20), link = rd32(sh + 24), entsize = rd32(sh + 36);
      size_t strsh = shoff + link * shentsize;
      uint32_t stroff = rd32(strsh + 16);
      for (uint32_t s = 0; s < size / entsize; s++) {
        size_t e = off + s * entsize;
        uint32_t name = rd32(e), value = rd32(e + 4);
        const char* n = reinterpret_cast<const char*>(&d.at(stroff + name));
        if (*n) img.symbols[n] = value;
      }
    }
    return img;
  }

  bool has(const std::string& s) const { return symbols.count(s) != 0; }
  uint32_t sym(const std::string& s) const {
    auto it = symbols.find(s);
    if (it == symbols.end()) throw std::runtime_error("missing ELF symbol " + s);
    return it->second;
  }

  // Copy all segments through a byte writer (zero-fills .bss part).
  void write_to(const std::function<void(uint32_t, uint8_t)>& wr) const {
    for (auto& s : segments)
      for (uint32_t i = 0; i < s.memsz; i++) wr(s.paddr + i, i < s.bytes.size() ? s.bytes[i] : 0);
  }
};

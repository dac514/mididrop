--[[
  Standard MIDI File parser. Run with `just test tests/smf_test.lua`.
]]

local t = require "tests.helper"
local mb = require "tests.midi_builder"
local smf = require "src.smf"

-- Variable length values ------------------------------------------------------

t.eq(mb.vlq(0), "\0", "builder vlq 0")
t.eq(mb.vlq(0x80), "\129\0", "builder vlq 0x80")

-- Basic type 0 file -----------------------------------------------------------

do
  local bytes = mb.file {
    ppq = 96,
    tracks = {
      mb.track {
        { 0, mb.meta(0x03, "Arp") },
        { 0, mb.meta(0x51, "\7\161\32") }, -- 500000 us = 120 BPM
        { 0, 0x90, 60, 100 },
        { 48, 0x80, 60, 0 },
        { 0, 0x90, 64, 90 },
        { 200, 0x80, 64, 64 }, -- long delta: 2-byte VLQ
      },
    },
  }
  local song, err = smf.parse(bytes)
  t.check(song ~= nil, "type 0 parses: " .. tostring(err))
  ---@cast song SmfSong
  t.eq(song.format, 0, "format")
  t.eq(song.ppq, 96, "ppq")
  t.eq(song.track_count, 1, "track count")
  t.eq(song.name, "Arp", "track name")
  t.eq(#song.tempos, 1, "one tempo")
  t.eq(song.tempos[1].bpm, 120, "tempo bpm")
  t.eq(#song.notes, 2, "two notes")
  t.eq(song.notes[1].pitch, 60, "first pitch")
  t.eq(song.notes[1].dur, 48, "first duration")
  t.eq(song.notes[1].vel, 100, "first velocity")
  t.eq(song.notes[1].ch, 1, "channel is 1-based")
  t.eq(song.notes[2].tick, 48, "second start")
  t.eq(song.notes[2].dur, 200, "second duration")
  t.eq(song.length_ticks, 248, "length")
end

-- Running status and velocity-0 note-offs -------------------------------------

do
  local bytes = mb.file {
    tracks = {
      mb.track {
        { 0, 0x91, 60, 100 },
        { 0, mb.RS, 64, 100 }, -- running status note-on
        { 0, mb.RS, 67, 100 },
        { 24, mb.RS, 60, 0 }, -- running status, velocity 0 = off
        { 0, mb.RS, 64, 0 },
        { 0, mb.RS, 67, 0 },
        { 0, 0xA1, 60, 10 }, -- poly pressure, then running status
        { 0, mb.RS, 61, 10 },
        { 0, 0xC1, 5 }, -- program change: 1 data byte
        { 0, mb.RS, 6 },
        { 0, 0x91, 70, 50 },
        { 12, 0x81, 70, 0 },
      },
    },
  }
  local song, err = smf.parse(bytes)
  t.check(song ~= nil, "running status parses: " .. tostring(err))
  ---@cast song SmfSong
  t.eq(#song.notes, 4, "chord plus one note")
  t.eq(song.notes[1].pitch, 60, "sorted by pitch at the same tick")
  t.eq(song.notes[3].pitch, 67, "third chord note")
  t.eq(song.notes[3].dur, 24, "velocity-0 ends the note")
  t.eq(song.notes[1].ch, 2, "channel 2")
  t.eq(song.notes[4].pitch, 70, "note after pressure and program change")
  t.eq(song.notes[4].tick, 24, "start after running status events")
end

-- Overlapping notes of the same pitch pair first-in first-out -----------------

do
  local bytes = mb.file {
    tracks = {
      mb.track {
        { 0, 0x90, 60, 100 },
        { 10, 0x90, 60, 80 },
        { 10, 0x80, 60, 0 },
        { 10, 0x80, 60, 0 },
      },
    },
  }
  local song = smf.parse(bytes) --[[@as SmfSong]]
  t.eq(#song.notes, 2, "two overlapping notes")
  t.eq(song.notes[1].dur, 20, "first on pairs with first off")
  t.eq(song.notes[2].dur, 20, "second on pairs with second off")
  t.eq(song.notes[2].vel, 80, "second velocity")
end

-- Notes left on end with the track --------------------------------------------

do
  local bytes =
    mb.file { tracks = { mb.track { { 0, 0x90, 60, 100 }, { 96, mb.meta(0x01, "x") } } } }
  local song = smf.parse(bytes) --[[@as SmfSong]]
  t.eq(#song.notes, 1, "hanging note kept")
  t.eq(song.notes[1].dur, 96, "hanging note ends at end of track")
end

-- Type 1: tracks merged, sysex skipped, "MTrk" inside data ignored -------------

do
  local conductor =
    mb.track { { 0, mb.meta(0x51, "\7\161\32") }, { 0, mb.meta(0x01, "MTrk inside text") } }
  local a = mb.track {
    { 0, mb.raw("\240" .. mb.vlq(4) .. "MTrk") }, -- sysex containing "MTrk"
    { 96, 0x90, 36, 120 },
    { 24, 0x80, 36, 0 },
  }
  local b = mb.track { { 0, 0x99, 42, 90 }, { 12, 0x89, 42, 0 } }
  local song, err = smf.parse(mb.file { ppq = 96, tracks = { conductor, a, b } })
  t.check(song ~= nil, "type 1 parses: " .. tostring(err))
  ---@cast song SmfSong
  t.eq(song.format, 1, "format 1")
  t.eq(song.track_count, 3, "three tracks")
  t.eq(#song.notes, 2, "notes merged from both tracks")
  t.eq(song.notes[1].pitch, 42, "sorted by tick across tracks")
  t.eq(song.notes[1].ch, 10, "drum channel")
  t.eq(song.notes[2].tick, 96, "second track note after sysex")
end

-- Format 2 is accepted --------------------------------------------------------

do
  local song = smf.parse(
    mb.file { format = 2, tracks = { mb.track { { 0, 0x90, 60, 1 }, { 1, 0x80, 60, 0 } } } }
  )
  t.check(song ~= nil and song.format == 2, "format 2 parses")
end

-- RIFF RMID container -----------------------------------------------------------

do
  local inner = mb.file { tracks = { mb.track { { 0, 0x90, 60, 100 }, { 48, 0x80, 60, 0 } } } }
  local song, err = smf.parse(mb.rmid(inner))
  t.check(song ~= nil, "RMID parses: " .. tostring(err))
  t.eq(song and #song.notes, 1, "RMID note")
end

-- Missing end-of-track is tolerated --------------------------------------------

do
  local song = smf.parse(mb.file {
    tracks = { mb.track({ { 0, 0x90, 60, 100 }, { 48, 0x80, 60, 0 } }, { no_end = true }) },
  })
  t.eq(song and #song.notes, 1, "no end-of-track")
end

-- Errors ------------------------------------------------------------------------

do
  local song, err = smf.parse "hello world, not midi"
  t.eq(song, nil, "garbage rejected")
  t.eq(err, "not a MIDI file", "garbage message")

  song, err = smf.parse(mb.file { division = 0xE728, tracks = { mb.track {} } })
  t.eq(song, nil, "SMPTE rejected")
  t.check(err and err:find "SMPTE", "SMPTE message")

  song, err = smf.parse(mb.file { tracks = { mb.track { { 0, 60, 100 } } } })
  t.eq(song, nil, "data byte without status rejected")
  t.check(err and err:find "without a status", "running status message: " .. tostring(err))

  song, err = smf.parse("MThd" .. mb.u32(6) .. mb.u16(0) .. mb.u16(0) .. mb.u16(96))
  t.eq(song, nil, "no tracks rejected")
  t.eq(err, "MIDI file has no tracks", "no tracks message")

  song, err = smf.parse "MThd\0\0"
  t.eq(err, "truncated MIDI header", "truncated header")

  local nothing ---@type any
  local _, e2 = smf.parse(nothing)
  t.eq(e2, "no data", "nil input")
end

t.done()

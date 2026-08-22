-- Retail debuff durations (shared base). Horizon loads this table, then
-- applies handlers/database/debuff_horizon.lua for duration diffs only.
-- Spell/WS/JA/pet data from existing XIUI tables plus LSB scripts.

local durations = {};

durations.spells = {
    -- Weapon skills with debuffs (do not track Shield Break)
    [181] = {duration = 180, buffId = 149}, -- Shell Crusher - Defense Down
    [83] = {duration = 180, buffId = 149},  -- Armor Break - Defense Down
    [87] = {duration = 180, buffIds = {149, 147}}, -- Full Break - Defense Down & Attack Down
    [155] = {duration = 180, buffId = 149}, -- Tachi: Ageha - Defense Down
    [187] = {duration = 180, buffId = 149}, -- Garland of Bliss - Defense Down
    [89] = {duration = 180, buffId = 149},  -- Metatron Torment - Defense Down
    [85] = {duration = 180, buffId = 147},  -- Weapon Break - Attack Down
    [185] = {duration = 180, buffId = 147}, -- Gate of Tartarus - Attack Down
    [107] = {duration = 180, buffId = 147}, -- Infernal Scythe - Attack Down
    [16] = {duration = 90, buffId = 3},     -- Wasp Sting - Poison
    [17] = {duration = 90, buffId = 3},     -- Viper Bite - Poison
    [18] = {duration = 30, buffId = 11},    -- Shadowstitch - Bind
    [35] = {duration = 5, buffId = 10},     -- Flat Blade - Stun
    [115] = {duration = 5, buffId = 10},    -- Leg Sweep - Stun
    [2] = {duration = 5, buffId = 10},      -- Shoulder Tackle - Stun
    [65] = {duration = 5, buffId = 10},     -- Smash Axe - Stun
    [162] = {duration = 5, buffId = 10},    -- Brainshaker - Stun
    [145] = {duration = 5, buffId = 10},    -- Tachi: Hobaku - Stun

    -- Dia/Bio spells
    [23] = {duration = 60, kind = 'enfeeble'},   -- Dia
    [33] = {duration = 60, kind = 'enfeeble'},   -- Diaga
    [230] = {duration = 60, kind = 'enfeeble'},  -- Bio
    [24] = {duration = 120, kind = 'enfeeble'},  -- Dia II
    [231] = {duration = 120, kind = 'enfeeble'}, -- Bio II
    [25] = {duration = 180, kind = 'enfeeble'},  -- Dia III
    [232] = {duration = 180, kind = 'enfeeble'}, -- Bio III

    -- Helix spells (278-285 and 885-892)
    [278] = {duration = 90, buffId = 186, kind = 'helix'}, [279] = {duration = 90, buffId = 186, kind = 'helix'},
    [280] = {duration = 90, buffId = 186, kind = 'helix'}, [281] = {duration = 90, buffId = 186, kind = 'helix'},
    [282] = {duration = 90, buffId = 186, kind = 'helix'}, [283] = {duration = 90, buffId = 186, kind = 'helix'},
    [284] = {duration = 90, buffId = 186, kind = 'helix'}, [285] = {duration = 90, buffId = 186, kind = 'helix'},
    [885] = {duration = 90, buffId = 186, kind = 'helix'}, [886] = {duration = 90, buffId = 186, kind = 'helix'},
    [887] = {duration = 90, buffId = 186, kind = 'helix'}, [888] = {duration = 90, buffId = 186, kind = 'helix'},
    [889] = {duration = 90, buffId = 186, kind = 'helix'}, [890] = {duration = 90, buffId = 186, kind = 'helix'},
    [891] = {duration = 90, buffId = 186, kind = 'helix'}, [892] = {duration = 90, buffId = 186, kind = 'helix'},

    -- Regular debuff spells
    [58] = {duration = 120, kind = 'enfeeble'},  -- Paralyze
    [80] = {duration = 120, kind = 'enfeeble'},  -- Paralyze II
    [356] = {duration = 120, kind = 'enfeeble'}, -- Paralyga
    [56] = {duration = 180, kind = 'enfeeble'},  -- Slow
    [79] = {duration = 180, kind = 'enfeeble'},  -- Slow II
    [357] = {duration = 180, kind = 'enfeeble'}, -- Slowga
    [216] = {duration = 120, kind = 'enfeeble'}, -- Gravity
    [217] = {duration = 180, kind = 'enfeeble'}, -- Gravity II
    [366] = {duration = 120, kind = 'enfeeble'}, -- Graviga
    [254] = {duration = 180, kind = 'enfeeble'}, -- Blind
    [276] = {duration = 180, kind = 'enfeeble'}, -- Blind II
    [361] = {duration = 180, kind = 'enfeeble'}, -- Blindga
    [112] = {duration = 12, kind = 'enfeeble'},  -- Flash
    [59] = {duration = 120, kind = 'enfeeble'},  -- Silence
    [359] = {duration = 120, kind = 'enfeeble'}, -- Silencega
    [253] = {duration = 60, kind = 'enfeeble'},  -- Sleep
    [273] = {duration = 60, kind = 'enfeeble'},  -- Sleepga
    [363] = {duration = 60, kind = 'enfeeble'},  -- Sleepga II
    [259] = {duration = 90, buffId = 19, clearsBuffs = {2, 193}, kind = 'enfeeble'}, -- Sleep II
    [274] = {duration = 90, buffId = 19, clearsBuffs = {2, 193}, kind = 'enfeeble'}, -- Sleepga II
    [364] = {duration = 90, buffId = 19, clearsBuffs = {2, 193}, kind = 'enfeeble'}, -- Sleepga III
    [258] = {duration = 60, kind = 'enfeeble'},  -- Bind
    [362] = {duration = 60, kind = 'enfeeble'},  -- Bindga
    [252] = {duration = 5, kind = 'enfeeble'},   -- Stun
    [220] = {duration = 90, kind = 'enfeeble'},  -- Poison
    [221] = {duration = 120, kind = 'enfeeble'}, -- Poison II
    [222] = {duration = 150, kind = 'enfeeble'}, -- Poison III
    [225] = {duration = 90, kind = 'enfeeble'},  -- Poisonga
    [226] = {duration = 120, kind = 'enfeeble'}, -- Poisonga II
    [227] = {duration = 150, kind = 'enfeeble'}, -- Poisonga III
    [286] = {duration = 180, kind = 'enfeeble'}, -- Addle
    [841] = {duration = 120, kind = 'enfeeble'}, -- Distract
    [842] = {duration = 120, kind = 'enfeeble'}, -- Distract II
    [843] = {duration = 120, kind = 'enfeeble'}, -- Distract III
    [844] = {duration = 120, kind = 'enfeeble'}, -- Frazzle
    [845] = {duration = 120, kind = 'enfeeble'}, -- Frazzle II
    [846] = {duration = 120, kind = 'enfeeble'}, -- Frazzle III
    [255] = {duration = 30, kind = 'enfeeble'},  -- Break
    [365] = {duration = 30, kind = 'enfeeble'},  -- Breakga
    [879] = {duration = 300, kind = 'enfeeble'}, -- Inundation

    -- Ninjutsu debuffs
    [341] = { duration = 180 }, -- Jubaku: Ichi
    [342] = { duration = 300 }, -- Jubaku: Ni
    [343] = { duration = 420 }, -- Jubaku: San
    [344] = { duration = 180 }, -- Hojo: Ichi
    [345] = { duration = 300 }, -- Hojo: Ni
    [346] = { duration = 420 }, -- Hojo: San
    [347] = { duration = 180 }, -- Kurayami: Ichi
    [348] = { duration = 300 }, -- Kurayami: Ni
    [349] = { duration = 420 }, -- Kurayami: San
    [350] = { duration = 60 },  -- Dokumori: Ichi
    [351] = { duration = 120 }, -- Dokumori: Ni
    [352] = { duration = 360 }, -- Dokumori: San

    -- Elemental debuffs (Burn, Frost, Choke, Rasp, Shock, Drown)
    [235] = {duration = 90, kind = 'elemental'}, [236] = {duration = 90, kind = 'elemental'},
    [237] = {duration = 90, kind = 'elemental'}, [238] = {duration = 90, kind = 'elemental'},
    [239] = {duration = 90, kind = 'elemental'}, [240] = {duration = 90, kind = 'elemental'},

    -- Threnodies I
    [454] = {duration = 60, songFamily = 'songPlusThrenody'},
    [455] = {duration = 60, songFamily = 'songPlusThrenody'},
    [456] = {duration = 60, songFamily = 'songPlusThrenody'},
    [457] = {duration = 60, songFamily = 'songPlusThrenody'},
    [458] = {duration = 60, songFamily = 'songPlusThrenody'},
    [459] = {duration = 60, songFamily = 'songPlusThrenody'},
    [460] = {duration = 60, songFamily = 'songPlusThrenody'},
    [461] = {duration = 60, songFamily = 'songPlusThrenody'},
    -- Threnodies II
    [871] = {duration = 90, songFamily = 'songPlusThrenody'},
    [872] = {duration = 90, songFamily = 'songPlusThrenody'},
    [873] = {duration = 90, songFamily = 'songPlusThrenody'},
    [874] = {duration = 90, songFamily = 'songPlusThrenody'},
    [875] = {duration = 90, songFamily = 'songPlusThrenody'},
    [876] = {duration = 90, songFamily = 'songPlusThrenody'},
    [877] = {duration = 90, songFamily = 'songPlusThrenody'},
    [878] = {duration = 90, songFamily = 'songPlusThrenody'},

    -- Elegies
    [421] = {duration = 120, songFamily = 'songPlusElegy'}, -- Battlefield Elegy
    [422] = {duration = 180, songFamily = 'songPlusElegy'}, -- Carnage Elegy
    [423] = {duration = 180, songFamily = 'songPlusElegy'}, -- Massacre Elegy

    -- Requiem I-VII
    [368] = {duration = 64, songFamily = 'songPlusRequiem'},
    [369] = {duration = 80, songFamily = 'songPlusRequiem'},
    [370] = {duration = 96, songFamily = 'songPlusRequiem'},
    [371] = {duration = 112, songFamily = 'songPlusRequiem'},
    [372] = {duration = 128, songFamily = 'songPlusRequiem'},
    [373] = {duration = 144, songFamily = 'songPlusRequiem'},
    [374] = {duration = 160, songFamily = 'songPlusRequiem'},

    -- Lullaby (376/377 Horde, 463/471 Foe)
    [376] = {duration = 30, songFamily = 'songPlusLullaby'}, -- Horde Lullaby
    [377] = {duration = 60, songFamily = 'songPlusLullaby'}, -- Horde Lullaby II
    [463] = {duration = 30, songFamily = 'songPlusLullaby'}, -- Foe Lullaby
    [471] = {duration = 60, songFamily = 'songPlusLullaby'}, -- Foe Lullaby II

    [466] = {duration = 30, songFamily = 'songPlusVirelai'}, -- Maiden's Virelai
    [472] = {duration = 120, songFamily = 'songPlusNocturne'}, -- Pining Nocturne

    -- Blue Magic from LSB scripts/actions/spells/blue. Physical/breath AE uses onDamage.
    [513] = {duration = 60, buffId = 3}, -- Venom Shell - Poison
    [515] = {duration = 60, buffId = 136, onDamage = true}, -- Maelstrom - STR Down
    [524] = {duration = 60, buffId = 146, onDamage = true}, -- Sandspin - Accuracy Down
    [531] = {duration = 30, buffId = 11, onDamage = true}, -- Ice Break - Bind
    [532] = {duration = 5, buffId = 10, onDamage = true}, -- Blitzstrahl - Stun
    [534] = {duration = 60, buffId = 12, onDamage = true}, -- Mysterious Light - Weight
    [535] = {duration = 60, buffId = 129}, -- Cold Wave - Frost
    [536] = {duration = 60, buffId = 3, onDamage = true}, -- Poison Breath - Poison
    [537] = {duration = 60, buffId = 138}, -- Stinking Gas - VIT Down
    [539] = {duration = 60, buffId = 147, onDamage = true}, -- Terror Touch - Attack Down
    [548] = {duration = 90, buffId = 13}, -- Filamented Hold - Slow
    [555] = {duration = 60, buffId = 12, onDamage = true}, -- Magnetite Cloud - Weight
    [561] = {duration = 180, buffId = 149}, -- Frightful Roar - Defense Down
    [563] = {duration = 60, buffId = 5, onDamage = true}, -- Hecatomb Wave - Blind
    [565] = {duration = 60, buffId = 13, buffIds = {13, 6}, onDamage = true}, -- Radiant Breath - Slow + Silence
    [572] = {duration = 30, buffId = 140}, -- Sound Blast - INT Down
    [575] = {duration = 5, buffId = 28}, -- Jettatura - Terror
    [576] = {duration = 90, buffId = 2}, -- Yawn - Sleep
    [582] = {duration = 120, buffId = 6}, -- Chaotic Eye - Silence
    [584] = {duration = 60, buffId = 2}, -- Sheep Song - Sleep
    [588] = {duration = 60, buffId = 31}, -- Lowing - Plague
    [596] = {duration = 60, buffId = 2, onDamage = true}, -- Pinecone Bomb - Sleep
    [597] = {duration = 180, buffId = 13, onDamage = true}, -- Sprout Smack - Slow
    [598] = {duration = 90, buffId = 2}, -- Soporific - Sleep
    [599] = {duration = 180, buffId = 3, onDamage = true}, -- Queasyshroom - Poison
    [603] = {duration = 60, buffId = 138, onDamage = true}, -- Wild Oats - VIT Down
    [604] = {duration = 60, buffId = 13, buffIds = {13, 6, 4, 11, 12, 3, 5}, onDamage = true}, -- Bad Breath
    [606] = {duration = 30, buffId = 136}, -- Awful Eye - STR Down
    [608] = {duration = 60, buffId = 4, onDamage = true}, -- Frost Breath - Paralyze
    [610] = {duration = 60, buffId = 148}, -- Infrasonics - Evasion Down
    [611] = {duration = 180, buffId = 3, onDamage = true}, -- Disseverment - Poison
    [612] = {duration = 16, buffId = 156}, -- Actinic Burst - Flash
    [616] = {duration = 5, buffId = 10}, -- Temporal Shift - Stun
    [618] = {duration = 30, buffId = 11, onDamage = true}, -- Blastbomb - Bind
    [620] = {duration = 60, buffId = 137, onDamage = true}, -- Battle Dance - DEX Down
    [621] = {duration = 120, buffId = 5}, -- Sandspray - Blind
    [623] = {duration = 5, buffId = 10, onDamage = true}, -- Head Butt - Stun
    [628] = {duration = 5, buffId = 10, onDamage = true}, -- Frypan - Stun
    [633] = {duration = 30, buffId = 149, buffIds = {149, 167}}, -- Enervation - Def Down + MDB Down
    [634] = {duration = 30, buffId = 5, buffIds = {5, 11}}, -- Light of Penance - Blind + Bind
    [638] = {duration = 180, buffId = 3, onDamage = true}, -- Feather Storm - Poison
    [640] = {duration = 5, buffId = 10, onDamage = true}, -- Tail Slap - Stun
    [644] = {duration = 90, buffId = 4, onDamage = true}, -- Mind Blast - Paralyze
    [648] = {duration = 30, buffId = 11, onDamage = true}, -- Regurgitation - Bind
    [650] = {duration = 120, buffId = 149, onDamage = true}, -- Seedspray - Defense Down
    [651] = {duration = 90, buffId = 149, buffIds = {149, 147}}, -- Corrosive Ooze - Def/Atk Down
    [652] = {duration = 60, buffId = 146, onDamage = true}, -- Spiral Spin - Accuracy Down
    [654] = {duration = 180, buffId = 4, onDamage = true}, -- Sub-zero Smash - Paralyze
    [660] = {duration = 90, buffId = 13}, -- Cimicine Discharge - Slow
    [669] = {duration = 5, buffId = 10, onDamage = true}, -- Whirl of Rage - Stun
    [671] = {duration = 60, buffId = 6, buffIds = {6, 11}, onDamage = true}, -- Auroral Drape - Silence + Bind
    [675] = {duration = 60, buffId = 5, onDamage = true}, -- Thermal Pulse - Blind
    [678] = {duration = 90, buffId = 2}, -- Dream Flower - Sleep
    [682] = {duration = 30, buffId = 31, onDamage = true}, -- Delta Thrust - Plague
    [687] = {duration = 60, buffId = 6}, -- Water Bomb - Silence (no LSB script)
    [692] = {duration = 5, buffId = 10, onDamage = true}, -- Sudden Lunge - Stun
    [699] = {duration = 60, buffId = 146, onDamage = true}, -- Barbed Crescent - Accuracy Down
    [703] = {duration = 180, buffId = 13}, -- Embalming Earth - Slow
    [704] = {duration = 60, buffId = 4, onDamage = true}, -- Paralyzing Triad - Paralyze
    [705] = {duration = 60, buffId = 133}, -- Foul Waters - Drown
    [707] = {duration = 12, buffId = 156}, -- Retinal Glare - Flash
};

-- Type 3 job abilities that land like a weaponskill.
durations.jaPhysical = {
    [22] = {duration = 120, buffId = 144}, -- Energy Drain - Max HP Down
    [45] = {duration = 30, buffId = 448},  -- Mug
    [46] = {duration = 8, buffId = 10},    -- Shield Bash - Stun (LSB 2-8)
    [77] = {duration = 8, buffId = 10},    -- Weapon Bash - Stun
    [170] = {duration = 30, buffId = 149}, -- Angon - Defense Down
};

-- Type 6 / 14 job abilities. 2-hour keys stay here so they do not collide with BLU spells.
durations.ja = {
    [72] = {duration = 30, buffId = 11}, -- Shadowbind - Bind
    [139] = {duration = 30, buffId = 149}, -- Tomahawk - Defense Down
    [201] = {duration = 30, buffId = 386}, -- Quickstep - Lethargic Daze
    [202] = {duration = 30, buffId = 396}, -- Stutter Step - Weakened Daze
    [220] = {duration = 30, buffId = 391}, -- Box Step - Sluggish Daze
    [221] = {duration = 8, buffId = 10}, -- Violent Flourish - Stun
    [312] = {duration = 30, buffId = 448}, -- Feather Step - Bewildered Daze
    [321] = {duration = 60}, -- Bully
    [354] = {duration = 180, buffId = 463}, -- Sepulcher
    [688] = {duration = 45}, -- Mighty Strikes (legacy 2hr tracking)
    [690] = {duration = 45}, -- Hundred Fists
    [691] = {duration = 60}, -- Manafont
    [693] = {duration = 30}, -- Perfect Dodge
    [694] = {duration = 30}, -- Invincible
    [695] = {duration = 30}, -- Blood Weapon
};

durations.pet = {
    [1908] = {duration = 60, buffId = 2}, -- Nightmare
};

-- Additional-effect procs keyed by the landed buff id (not spell/WS id).
durations.additionalEffect = {
    [2] = {duration = 25},   -- Sleep Bolt
    [149] = {duration = 60}, -- Defense Down / Acid Bolt
    [12] = {duration = 30},  -- Gravity / Mandau
};

return durations;

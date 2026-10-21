// That Which Gave Chase autosplitter
//
// How it splits: the game saves a checkpoint as the active scene's build index
// plus a progress flag within that scene. Every checkpoint belongs to one of
// the game's 13 levels, and a split happens when the run first enters a level
// it has not been in yet.
//
// Where I read them: the registry. Both values are Unity PlayerPrefs, and on
// Windows Unity writes PlayerPrefs to the registry as soon as they are set,
// even though the game never calls PlayerPrefs.Save(). That makes the splits
// themselves independent of memory addresses, so a game update can't break
// them.

state("That Which Gave Chase") { }

startup
{
    vars.RegPath   = @"Software\AslakKH\That Which Gave Chase";
    vars.SceneKey  = "SceneCheckpoint_h2599826225";
    vars.FlagKey   = "ProgressFlagCheckpoint_h1283111326";
    vars.TimeKey   = "CheckpointTime_h894711546";

    // The 13 levels in route order: the game's own scene-select list. Each
    // setting means "split when this level ends".
    vars.Levels = new List<string>
    {
        "Opening", "First Cabin", "Rifle", "Second Cabin", "First Cabin Reprise",
        "Ice", "Chase", "Second Cabin (part 2)", "Cave", "Outside Cave",
        "Forest", "Confrontation", "Epilogue"
    };

    settings.Add("splits", true, "Split at the end of each level");
    foreach (string level in vars.Levels)
    {
        settings.Add(level, true, level, "splits");
    }

    // Subscene splits: every checkpoint, in route order (Third Section plays
    // flags 7, 6, 5), keyed "build index:flag". Optional and off by default.
    // Epilogue flag 2 is left out because it is the run's ending, which the
    // final level split already covers.
    //
    // The parent setting is off and the children are on, so ticking the
    // parent turns them all on and any one can then be unticked.
    vars.Subs = new List<KeyValuePair<string, string>>
    {
        new KeyValuePair<string, string>("4:0",  "Opening"),
        new KeyValuePair<string, string>("4:2",  "First Cabin"),
        new KeyValuePair<string, string>("4:3",  "Night Walk"),
        new KeyValuePair<string, string>("6:0",  "Rifle"),
        new KeyValuePair<string, string>("6:1",  "Rifle Walk"),
        new KeyValuePair<string, string>("6:2",  "Second Cabin"),
        new KeyValuePair<string, string>("6:3",  "First Cabin Reprise"),
        new KeyValuePair<string, string>("8:0",  "Ice (Prelude)"),
        new KeyValuePair<string, string>("8:1",  "Ice"),
        new KeyValuePair<string, string>("8:3",  "Chase"),
        new KeyValuePair<string, string>("8:4",  "Post-Chase"),
        new KeyValuePair<string, string>("8:7",  "Second Cabin Reprise"),
        new KeyValuePair<string, string>("8:6",  "Opening Reprise"),
        new KeyValuePair<string, string>("8:5",  "Night Walk Reprise"),
        new KeyValuePair<string, string>("11:0", "Cave"),
        new KeyValuePair<string, string>("12:0", "Outside Cave"),
        new KeyValuePair<string, string>("12:1", "Sled Trail Walk (Tripping Scene)"),
        new KeyValuePair<string, string>("12:2", "Forest (First 2 Dogs/Rifle)"),
        new KeyValuePair<string, string>("12:3", "Forest (Third Dog/Find Sled)"),
        new KeyValuePair<string, string>("12:4", "Forest (Final Dog/Lift Sled/Go)"),
        new KeyValuePair<string, string>("12:5", "Blizzard Deer Chase"),
        new KeyValuePair<string, string>("12:6", "Pre-Confrontation"),
        new KeyValuePair<string, string>("12:7", "Confrontation"),
        new KeyValuePair<string, string>("13:0", "Epilogue (Flat)"),
        new KeyValuePair<string, string>("13:1", "Epilogue (Hills)")
    };

    settings.Add("subs", false, "Also split at the end of each subscene");
    var subKeys = new HashSet<string>();
    foreach (var sub in vars.Subs)
    {
        settings.Add("sub:" + sub.Key, true, sub.Value, "subs");
        subKeys.Add(sub.Key);
    }
    vars.SubKeys = subKeys;

    // Logging goes to DebugView and to %TEMP%\TWGC-autosplitter.log, so a
    // problem can be checked against real timings afterwards. It is named
    // TLog rather than Log because asl-help defines its own vars.Log when it
    // loads and would silently replace mine.
    string logPath = Path.Combine(Path.GetTempPath(), "TWGC-autosplitter.log");
    vars.LogPath = logPath;
    vars.TLog = (Action<object>)(s =>
    {
        string line = DateTime.Now.ToString("HH:mm:ss.fff") + "  " + s;
        print("[TWGC] " + s);
        try
        {
            // Rolled over at 5 MB so the file never grows without bound.
            var fi = new FileInfo(logPath);
            if (fi.Exists && fi.Length > 5L * 1024 * 1024) File.Copy(logPath, logPath + ".old", true);
            if (fi.Exists && fi.Length > 5L * 1024 * 1024) File.Delete(logPath);
            File.AppendAllText(logPath, line + Environment.NewLine);
        }
        catch { }
    });
    vars.TLog("---- script loaded ----");

    // One clock for every precise timing. The load thread stamps events on a
    // Stopwatch, and DateTime.Now on .NET Framework only moves in steps of up
    // to about 15 ms, so anything compared against a thread time uses this.
    var clockSw = System.Diagnostics.Stopwatch.StartNew();
    long clockT0 = DateTime.Now.Ticks;
    vars.Now = (Func<long>)(() => clockT0 + clockSw.Elapsed.Ticks);

    // Seconds from the blue (Epilogue flag 2) to the first frame of the title
    // card. Only a fallback, for when the title card itself can't be watched
    // (see TITLE CARD WATCH in update); it is the average of several timed
    // endings, which ranged from about 28.03 to 28.12 s.
    vars.EndDelay = 28.08;

    // 1 ms timer resolution for the load thread (see PRECISE LOADS in init).
    // Windows sleeps in ~15.6 ms steps unless the process asks for 1 ms, and
    // ASL code can't declare a P/Invoke, so I emit one here.
    try
    {
        var ab = AppDomain.CurrentDomain.DefineDynamicAssembly(
            new System.Reflection.AssemblyName("TwgcWinmm"), System.Reflection.Emit.AssemblyBuilderAccess.Run);
        var tbld = ab.DefineDynamicModule("TwgcWinmm").DefineType("Winmm", System.Reflection.TypeAttributes.Public);
        foreach (string fn in new[] { "timeBeginPeriod", "timeEndPeriod" })
        {
            var mb = tbld.DefinePInvokeMethod(fn, "winmm.dll",
                System.Reflection.MethodAttributes.Public | System.Reflection.MethodAttributes.Static | System.Reflection.MethodAttributes.PinvokeImpl,
                System.Reflection.CallingConventions.Standard, typeof(uint), new[] { typeof(uint) },
                System.Runtime.InteropServices.CallingConvention.Winapi, System.Runtime.InteropServices.CharSet.Auto);
            mb.SetImplementationFlags(mb.GetMethodImplementationFlags() | System.Reflection.MethodImplAttributes.PreserveSig);
        }
        var winmm = tbld.CreateType();
        var beginM = winmm.GetMethod("timeBeginPeriod");
        var endM = winmm.GetMethod("timeEndPeriod");
        vars.TimeBegin = (Action)(() => beginM.Invoke(null, new object[] { 1u }));
        vars.TimeEnd = (Action)(() => endM.Invoke(null, new object[] { 1u }));
    }
    catch (Exception e)
    {
        vars.TimeBegin = (Action)(() => { });
        vars.TimeEnd = (Action)(() => { });
        vars.TLog("1 ms timer unavailable: " + e.Message);
    }

    // asl-help is optional. Without it the checkpoint splits still work; it
    // adds the start on "Yes", the reset on quitting to the menu, load
    // removal and the title card watch.
    vars.HasHelper = File.Exists("Components/asl-help");

    // Slow ticks until init succeeds; init raises this to 60 Hz.
    refreshRate = 4;
    if (vars.HasHelper)
    {
        // Code generation off. By default asl-help puts
        // "if (!vars.Helper.Loaded) return false;" at the top of update. If
        // LiveSplit attaches the moment the game launches, asl-help's module
        // search can give up before Unity is ready, Loaded then stays false,
        // and that line skips every update, checkpoint splits included. So I
        // call Load() myself once the game is ready (init) and check Loaded
        // myself (update), and the registry side never waits on asl-help.
        // This is asl-help's own documented opt-out.
        var helperType = Assembly.Load(File.ReadAllBytes("Components/asl-help")).GetType("Unity");
        vars.Helper = Activator.CreateInstance(helperType, false);

        // asl-help's own diagnostics (module search, TryLoad result).
        vars.Helper.StartFileLogger(Path.Combine(Path.GetTempPath(), "TWGC-asl-help.log"));
        vars.Helper.GameName = "That Which Gave Chase";
        vars.Helper.LoadSceneManager = true;
        settings.Add("menuReset", true, "Reset when quitting to the main menu");
    }
    else
    {
        settings.Add("menuReset", false, "Reset on quit to menu (needs Components/asl-help, not installed)");
    }

    // Build index plus flag to level. The build indices come from the game's
    // globalgamemanagers. Several levels span more than one flag, and flags
    // between levels belong to the level already underway, so those return
    // null and the run stays in its current level.
    //
    // Epilogue flag 2 is the blue section where control is lost. It isn't a
    // level; reaching it arms the final split (see update).
    vars.LevelOf = (Func<int, int, string>)((scene, flag) =>
    {
        switch (scene)
        {
            case 4: // PostTitleScene
                if (flag == 0) return "Opening";
                if (flag == 2 || flag == 3) return "First Cabin";
                break;
            case 6: // SecondSectionScene
                if (flag == 0 || flag == 1) return "Rifle";
                if (flag == 2) return "Second Cabin";
                if (flag == 3) return "First Cabin Reprise";
                break;
            case 8: // ThirdSectionScene. Part 2 plays in the order 7, 6, 5.
                if (flag == 0 || flag == 1) return "Ice";
                if (flag == 3 || flag == 4) return "Chase";
                if (flag >= 5 && flag <= 7) return "Second Cabin (part 2)";
                break;
            case 11: // CaveScene
                if (flag == 0) return "Cave";
                break;
            case 12: // FinalSectionScene
                if (flag == 0 || flag == 1) return "Outside Cave";
                if (flag >= 2 && flag <= 6) return "Forest";
                if (flag == 7) return "Confrontation";
                break;
            case 13: // EpilogueScene
                if (flag == 0 || flag == 1) return "Epilogue";
                if (flag == 2) return "END";
                break;
        }
        return null;
    });

    // Why the read is shaped like this: on a scene change the game writes the
    // scene, then the flag, then CheckpointTime (the flag setter stamps it).
    // A read that lands between the scene and the flag sees the new scene
    // with the old flag, which can look like a real checkpoint (4:3 then 6:3
    // would read as First Cabin Reprise) and would use up that split early.
    // So nothing acts on the pair unless the stamp moved, and I read the stamp
    // before and after the pair: if the two differ, a write happened mid-read
    // and I throw the read away for this tick.
    //
    // Returns false if the values are absent (a save that has never started a
    // run) or the read was torn.
    string regPath = vars.RegPath, sceneKey = vars.SceneKey, flagKey = vars.FlagKey, timeKey = vars.TimeKey;
    Func<Microsoft.Win32.RegistryKey, string> readTime = k =>
    {
        // PlayerPrefs strings land as null-terminated bytes.
        var b = k.GetValue(timeKey) as byte[];
        return b == null ? "" : System.Text.Encoding.ASCII.GetString(b).TrimEnd('\0');
    };
    vars.ReadPrefs = (Func<bool>)(() =>
    {
        using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(regPath))
        {
            if (k == null) return false;
            string t1 = readTime(k);
            object s = k.GetValue(sceneKey);
            object f = k.GetValue(flagKey);
            string t2 = readTime(k);
            if (s == null || f == null || t1 != t2) return false;
            vars.Scene = (int)s;
            vars.Flag  = (int)f;
            vars.Time  = t2;
            return true;
        }
    });
}

init
{
    // Wait for the game to finish starting before asl-help looks at it.
    // Throwing here makes LiveSplit run init again on its next tick (init only
    // counts as done once it returns), and startup set that tick to 4 Hz, so
    // the wait costs a handful of event-log lines rather than hundreds.
    if (vars.HasHelper)
    {
        bool ready = false;
        try
        {
            double up = (DateTime.Now - game.StartTime).TotalSeconds;
            bool unity = false, mono = false;
            foreach (ProcessModule m in game.Modules)
            {
                string n = m.ModuleName.ToLowerInvariant();
                if (n == "unityplayer.dll") unity = true;
                if (n.StartsWith("mono")) mono = true;
            }
            ready = up >= 5.0 && unity && mono;
        }
        catch { ready = false; }
        if (!ready) throw new Exception("TWGC: waiting for the game to finish starting");
    }

    // 60 Hz, so the main checks lag events by one tick at most.
    refreshRate = 60;

    // Attaching and detaching are logged so it's always clear whether the
    // script is connected to the game.
    vars.TLog("attached to game, pid " + game.Id + ", asl-help " + (vars.HasHelper ? "present" : "absent"));
    vars.FirstUpdate = true;
    vars.SkipMenuEdge = false;

    // THE CLICK. Every main-menu button that commits to something (Yes, New on
    // a fresh save, Continue, scene select, brightness) disables the menu's
    // EventSystem in the same frame, and Unity's UI keeps the enabled ones in
    // the static list EventSystem.m_EventSystems. Its count dropping to 0 on
    // the menu is the click. List<T>._size sits at 0x18 in 64-bit Mono.
    vars.InputOk = false;
    vars.InputErrLogged = false;
    vars.InputFirstLogged = false;
    vars.EsField = IntPtr.Zero;
    vars.EsCount = -1;
    vars.GrField = IntPtr.Zero;
    vars.GrOffs = new int[0];
    vars.GrLast = "";

    // Every live canvas in Unity's UI registry as {graphic list pointer,
    // size}. Layout: the Dictionary's entries at +0x18, slots used at +0x40;
    // entry {int hash, int next, Canvas key, IndexedSet value}, 24 bytes each
    // from +0x20; the IndexedSet's List at +0x10, its size at +0x18.
    var gameRef = game;
    vars.CanvasLists = (Func<List<long[]>>)(() =>
    {
        var res = new List<long[]>();
        IntPtr field = vars.GrField;
        int[] offs = vars.GrOffs;
        if (field == IntPtr.Zero || offs.Length == 0) return res;
        IntPtr inst = gameRef.ReadPointer(field);
        IntPtr dict = inst == IntPtr.Zero ? IntPtr.Zero : gameRef.ReadPointer(inst + offs[0]);
        if (dict == IntPtr.Zero) return res;
        IntPtr entries = gameRef.ReadPointer(dict + 0x18);
        int used = gameRef.ReadValue<int>(dict + 0x40);
        if (used <= 0 || used >= 256) return res;
        byte[] arr = gameRef.ReadBytes(entries + 0x20, 24 * used);
        for (int i = 0; arr != null && i < used; i++)
        {
            if (BitConverter.ToInt32(arr, 24 * i) < 0) continue;
            IntPtr set = new IntPtr(BitConverter.ToInt64(arr, 24 * i + 16));
            IntPtr list = gameRef.ReadPointer(set + 0x10);
            if (list == IntPtr.Zero) continue;
            res.Add(new long[] { (long)list, gameRef.ReadValue<int>(list + 0x18) });
        }
        return res;
    });
    vars.EndAt = null;
    vars.FixSplitTo = null;
    vars.BlueAt = null;
    vars.TitleArmed = false;
    vars.TitleDone = false;
    vars.Loading = false;
    vars.LoadingOld = false;
    vars.LoadErrLogged = false;
    vars.LoadStartedAt = DateTime.Now;

    // PRECISE LOADS. A load runs from the scene load request to the new
    // scene's first playable frame. When the new scene activates, Unity drops
    // the old one from its scene list, and the new scene's setup takes the
    // next frames: the first frame of normal play is the third tick of
    // Unity's frame counter after the drop. I checked that against an
    // in-game load timer, to within a millisecond per load.
    //
    // A background thread polls the scene count and the frame counter about
    // every millisecond and queues each scene-count change with its exact
    // time; a drop is held until the counter has ticked 3 more times and
    // carries that moment as its end. update turns the queue into load spans,
    // and gameTime gives LiveSplit real time minus those spans.
    //
    // Addresses: g_runtimeSceneManager by asl-help's 64-bit pattern in
    // UnityPlayer.dll, count at +0x18. The frame counter is UnityPlayer +
    // 0x1A670C0, then +0x38, found by scanning the running game. It is only
    // valid for this UnityPlayer.dll (module size 29442048), so on any other
    // build a load ends at the drop instead.
    vars.LoadStop = new bool[1];
    vars.LoadEvents = new System.Collections.Concurrent.ConcurrentQueue<long[]>();
    vars.LoadStats = new long[2];
    // {watched list pointers, their sizes when armed, detection time, title time}
    vars.TitleWatch = new object[] { null, null, 0L, 0L };
    // {m_EventSystems field address (set once TryLoad has it), time of the
    // last drop to zero}. See CLICK TIMING in update.
    vars.ClickWatch = new long[] { 0L, 0L };
    vars.Spans = new List<long[]>();
    vars.RunStartAbs = 0L;
    // Load time removed between a run start and a moment, both on vars.Now's
    // clock: finished spans clipped to that window, plus the load in flight.
    vars.RemovedUpTo = (Func<long, long, long>)((runStart, at) =>
    {
        long removed = 0;
        foreach (long[] sp in vars.Spans)
        {
            long a = Math.Max(sp[0], runStart), b = Math.Min(sp[1], at);
            if (b > a) removed += b - a;
        }
        if (vars.InLoad)
        {
            long a = Math.Max((long)vars.LoadFrom, runStart);
            if (at > a) removed += at - a;
        }
        return removed;
    });
    vars.InLoad = false;
    vars.LoadFrom = 0L;
    vars.PreciseLoads = false;
    vars.StatsLogged = false;
    try
    {
        ProcessModule up = null;
        foreach (ProcessModule m in game.Modules)
            if (m.ModuleName.ToLowerInvariant() == "unityplayer.dll") up = m;
        long upBase = (long)up.BaseAddress;
        byte[] img = game.ReadBytes(up.BaseAddress, up.ModuleMemorySize);
        long mgrVar = 0;
        for (int i = 0; img != null && i + 13 <= img.Length; i++)
        {
            if (img[i] == 0x48 && img[i + 1] == 0x83 && img[i + 2] == 0xEC && img[i + 3] == 0x20 &&
                img[i + 4] == 0x4C && img[i + 5] == 0x8B && (img[i + 6] & 0x0F) == 0x05 &&
                img[i + 11] == 0x33 && img[i + 12] == 0xF6)
            {
                mgrVar = upBase + i + 11 + BitConverter.ToInt32(img, i + 7);
                break;
            }
        }
        if (mgrVar == 0) throw new Exception("scene manager pattern not found");
        bool knownBuild = up.ModuleMemorySize == 29442048;
        IntPtr mv = new IntPtr(mgrVar);
        IntPtr fv = knownBuild ? new IntPtr(upBase + 0x1A670C0) : IntPtr.Zero;

        var q = (System.Collections.Concurrent.ConcurrentQueue<long[]>)vars.LoadEvents;
        var stop = (bool[])vars.LoadStop;
        var stats = (long[])vars.LoadStats;
        var tw = (object[])vars.TitleWatch;
        var cw = (long[])vars.ClickWatch;
        var proc = game;
        Action tBegin = vars.TimeBegin, tEnd = vars.TimeEnd;
        Func<long> clockNow = vars.Now;
        var th = new Thread(() =>
        {
            try { tBegin(); } catch { }
            try
            {
                var sw = System.Diagnostics.Stopwatch.StartNew();
                int last = -1;
                var pending = new List<long[]>(); // {time, count, previous count, frame, end}
                IntPtr[] armedLists = null;
                int titleFrame = -1;
                int lastEs = -1;
                long lastPoll = 0;
                while (!stop[0])
                {
                    long now = clockNow();
                    IntPtr mgr = proc.ReadPointer(mv);
                    int count = mgr == IntPtr.Zero ? -1 : proc.ReadValue<int>(mgr + 0x18);
                    int frame = -1;
                    if (fv != IntPtr.Zero)
                    {
                        IntPtr fs = proc.ReadPointer(fv);
                        if (fs != IntPtr.Zero) frame = proc.ReadValue<int>(fs + 0x38);
                    }
                    if (count >= 0 && last >= 0 && count != last)
                        pending.Add(new long[] { now, count, last, frame, (count < last && frame >= 0) ? -1 : now });
                    if (count >= 0) last = count;
                    foreach (var ev in pending)
                    {
                        if (ev[4] != -1) continue;
                        if (frame >= ev[3] + 3) ev[4] = now;
                        else if (now - ev[0] > TimeSpan.TicksPerSecond * 2) ev[4] = ev[0]; // counter stalled: end at the drop
                    }
                    while (pending.Count > 0 && pending[0][4] != -1) { q.Enqueue(pending[0]); pending.RemoveAt(0); }
                    // CLICK TIMING (see update): the menu's input count
                    // dropping to zero, timed at the midpoint between this
                    // poll and the last, about a millisecond either way.
                    if (cw[0] != 0)
                    {
                        IntPtr esList = proc.ReadPointer(new IntPtr(cw[0]));
                        int es = esList == IntPtr.Zero ? -1 : proc.ReadValue<int>(esList + 0x18);
                        if (lastEs > 0 && es == 0) cw[1] = lastPoll > 0 ? (lastPoll + now) / 2 : now;
                        lastEs = es;
                    }
                    lastPoll = now;

                    // TITLE CARD WATCH (see update). The first watched canvas
                    // to gain a graphic is the title switching on; its time
                    // is the next frame tick, the first frame it is visible.
                    var lists = tw[0] as IntPtr[];
                    if (!ReferenceEquals(lists, armedLists)) { armedLists = lists; titleFrame = -1; }
                    if (lists != null && (long)tw[3] == 0L)
                    {
                        if (titleFrame < 0)
                        {
                            var baseSizes = (int[])tw[1];
                            for (int i = 0; i < lists.Length; i++)
                            {
                                if (proc.ReadValue<int>(lists[i] + 0x18) > baseSizes[i])
                                {
                                    tw[2] = now;
                                    if (frame < 0) tw[3] = now; else titleFrame = frame;
                                    break;
                                }
                            }
                        }
                        else if (frame > titleFrame) tw[3] = now;
                    }

                    stats[0]++; stats[1] = sw.Elapsed.Ticks;
                    Thread.Sleep(1);
                }
            }
            catch { }
            finally { try { tEnd(); } catch { } }
        });
        th.IsBackground = true;
        th.Start();
        vars.PreciseLoads = true;
        vars.TLog("precise loads on: scene manager at UnityPlayer+0x" + (mgrVar - upBase).ToString("X")
                + (knownBuild ? ", frame counter found" : ", UNKNOWN UnityPlayer build, loads end at the scene drop"));
    }
    catch (Exception e)
    {
        vars.TLog("precise loads unavailable, using the 60 Hz reading: " + e.Message);
    }

    if (vars.HasHelper)
    {
        vars.Helper.TryLoad = (Func<dynamic, bool>)(mono =>
        {
            var es = mono["UnityEngine.UI", "EventSystem", 0];
            // asl-help only resolves the address here. Its watchers don't
            // refresh with code generation off, so I read the count myself
            // with LiveSplit's own memory calls. _base is the static field's
            // address (statics plus the field's offset), as Make computed it.
            var p = mono.Make<int>(es, "m_EventSystems", 0x18);
            var baseField = p.GetType().BaseType.GetField("_base",
                System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
            vars.EsField = new IntPtr((long)(IntPtr)baseField.GetValue(p));
            vars.TLog("TryLoad: m_EventSystems field at 0x" + ((long)vars.EsField).ToString("X") + " (" + p.ToString() + ")");

            // The title card is a UI Image, and UI graphics register with
            // UnityEngine.UI.GraphicRegistry when they switch on. The TITLE
            // CARD WATCH (update) uses this; if it can't be found, the final
            // split falls back to a fixed delay.
            try
            {
                var gr = mono["UnityEngine.UI", "GraphicRegistry", 0];
                var gp = mono.Make<long>(gr, "s_Instance", "m_Graphics");
                var flags = System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance;
                vars.GrField = new IntPtr((long)(IntPtr)gp.GetType().BaseType.GetField("_base", flags).GetValue(gp));
                vars.GrOffs = (int[])gp.GetType().BaseType.GetField("_offsets", flags).GetValue(gp);
                vars.TLog("TryLoad: GraphicRegistry s_Instance at 0x" + ((long)vars.GrField).ToString("X") + " (" + gp.ToString() + ")");
            }
            catch (Exception e) { vars.TLog("TryLoad: GraphicRegistry not found: " + e.Message); }
            return true;
        });
        vars.Helper.Load();
    }
    vars.HelperReady = false;
    vars.HelperReadyOld = false;
    vars.ClickEdge = false;
    vars.ClickAt = DateTime.MinValue;
    vars.ClickPrecise = false;
    vars.Pending = false;
    vars.PendingSince = DateTime.MinValue;
    vars.CancelStart = false;

    vars.Scene = -1; vars.Flag = -1; vars.Time = "";
    vars.Wrote = false;
    vars.NewLevel = null;
    vars.Level = null;
    vars.Entered = new HashSet<string>();
    vars.NewSub = null;
    vars.Sub = null;
    vars.EnteredSubs = new HashSet<string>();
    vars.OnMenu = false;
    vars.OnMenuOld = false;
    vars.SceneErrLogged = false;
    vars.SceneOk = false;
    vars.Backdate = false;
    vars.SceneBefore = -1;

    // Baseline. A torn read is transient, so retry a few times; if the values
    // are simply absent (a save that has never started), the baseline stays
    // "" and the first write ever counts as a write.
    for (int i = 0; i < 5 && !vars.ReadPrefs(); i++) Thread.Sleep(5);
    vars.SceneAtStamp = vars.Time == "" ? -1 : vars.Scene;

    // Reloaded mid-run: init wipes the run state, so if the timer is already
    // running I rebuild it from the saved checkpoint. The run is in that
    // level, and every level and subscene before it in route order has been
    // entered. This also covers relaunching the game after a crash.
    if (timer.CurrentPhase == TimerPhase.Running && vars.Time != "")
    {
        string here = vars.LevelOf(vars.Scene, vars.Flag);
        string hereSub = vars.Scene + ":" + vars.Flag;
        // The Cave keeps the previous scene's stale flag (see update).
        if (vars.Scene == 11) { here = "Cave"; hereSub = "11:0"; }
        if (here != null && here != "END")
        {
            foreach (string level in vars.Levels)
            {
                vars.Entered.Add(level);
                if (level == here) break;
            }
            vars.Level = here;
        }
        if (vars.SubKeys.Contains(hereSub))
        {
            foreach (var sub in vars.Subs)
            {
                vars.EnteredSubs.Add(sub.Key);
                if (sub.Key == hereSub) break;
            }
            vars.Sub = hereSub;
        }
        vars.TLog("reloaded mid-run: resuming in " + (vars.Level ?? "(unknown level)")
                + " at " + hereSub);
    }
}

update
{
    // Active scene first, so a torn registry read can't hide a quit.
    // MainMenuScene is build index 1. The pause menu loads additively and
    // leaves the gameplay scene active, so pausing never reads as the menu.
    if (vars.FirstUpdate)
    {
        vars.FirstUpdate = false;
        vars.TLog("first update since attaching");
        vars.SkipMenuEdge = true;
    }

    // asl-help loads in the background after init. Everything that needs it
    // waits for Loaded; everything else runs regardless. Reading Loaded also
    // refreshes asl-help's memory watchers, so I read it once a tick.
    vars.HelperReadyOld = vars.HelperReady;
    if (vars.HasHelper)
    {
        try { vars.HelperReady = vars.Helper.Loaded; }
        catch (Exception e)
        {
            vars.HelperReady = false;
            if (!vars.SceneErrLogged) { vars.TLog("asl-help not usable: " + e.Message); vars.SceneErrLogged = true; }
        }
        if (vars.HelperReady && !vars.HelperReadyOld) vars.TLog("asl-help loaded");
    }

    vars.OnMenuOld = vars.OnMenu;
    if (vars.HelperReady)
    {
        try
        {
            vars.OnMenu = vars.Helper.Scenes.Active.Index == 1;
            vars.SceneOk = true;
        }
        catch (Exception e)
        {
            // Logged once, so a broken scene read is visible rather than
            // silent. SceneOk drops, and start falls back to the registry.
            vars.OnMenu = false;
            vars.SceneOk = false;
            if (!vars.SceneErrLogged) { vars.TLog("scene read failed: " + e.Message); vars.SceneErrLogged = true; }
        }
    }
    else
    {
        // asl-help still loading (or absent): no scene, no menu knowledge.
        vars.OnMenu = false;
        vars.SceneOk = false;
    }

    // The first read after attaching has no real "before". Without this, a
    // game relaunched onto its menu would look like a quit to menu and reset
    // the run, which would throw a run away after a crash. The same goes for
    // the first read after asl-help finishes loading.
    if (vars.SkipMenuEdge || (vars.HelperReady && !vars.HelperReadyOld))
    {
        vars.SkipMenuEdge = false;
        vars.OnMenuOld = vars.OnMenu;
    }

    // Menu input switching off, on the menu, is a click that committed.
    vars.ClickEdge = false;
    if (vars.HelperReady)
    {
        try
        {
            // Static field holds the List; List<T>._size sits at 0x18.
            IntPtr list = game.ReadPointer((IntPtr)vars.EsField);
            int esNow = list == IntPtr.Zero ? -1 : game.ReadValue<int>(list + 0x18);
            int esOld = vars.EsCount;
            vars.EsCount = esNow;
            vars.InputOk = esNow >= 0;
            if (!vars.InputFirstLogged)
            {
                vars.InputFirstLogged = true;
                esOld = esNow;
                vars.TLog("menu input first read: " + esNow + " (list at 0x" + ((long)list).ToString("X") + ")");
            }
            vars.ClickEdge = vars.OnMenu && esOld > 0 && esNow == 0;
            if (esNow != esOld) vars.TLog("menu input systems: " + esOld + " -> " + esNow);
        }
        catch (Exception e)
        {
            vars.InputOk = false;
            if (!vars.InputErrLogged) { vars.TLog("menu input read not ready or failed: " + e.Message); vars.InputErrLogged = true; }
        }
    }
    // CLICK TIMING. This 60 Hz tick sees the click up to 16 ms late, so the
    // load thread times the drop itself and that time becomes the click. The
    // New Game intro can't be used to work it out backwards: its waits run
    // on game time, so a hitch makes it longer than 11.0 s of real time.
    var cwMain = (long[])vars.ClickWatch;
    if (cwMain[0] == 0 && vars.EsField != IntPtr.Zero) cwMain[0] = (long)(IntPtr)vars.EsField;
    if (vars.ClickEdge)
    {
        long dropAt = cwMain[1];
        vars.ClickPrecise = vars.PreciseLoads && dropAt != 0
            && (long)vars.Now() - dropAt < TimeSpan.TicksPerMillisecond * 250;
        vars.ClickAt = new DateTime(vars.ClickPrecise ? dropAt : (long)vars.Now());
        vars.TLog("menu click (input switched off) at " + ((DateTime)vars.ClickAt).ToString("HH:mm:ss.fff")
                + (vars.ClickPrecise ? " (thread)" : " (60 Hz tick)"));
    }

    // A click start still waiting for New Game proof is cancelled if the menu
    // goes away first (Continue, scene select and brightness all load a
    // scene) or if nothing arrives well past the 11.0 s intro.
    if (vars.Pending && !vars.CancelStart)
    {
        if (vars.SceneOk && !vars.OnMenu)
        {
            vars.CancelStart = true;
            vars.TLog("left the menu before any New Game write: cancelling start");
        }
        else if ((new DateTime((long)vars.Now()) - (DateTime)vars.PendingSince).TotalSeconds > 15.0)
        {
            vars.CancelStart = true;
            vars.TLog("no New Game write 15 s after the click: cancelling start");
        }
    }

    // LOADS. A load runs from the scene load request to the new scene
    // arriving: the stretch where the game holds a finished load back
    // (allowSceneActivation false) and the fade inside SceneLoader.AsyncLoad
    // are removed, the fade before the request is not, and death reloads
    // count. Unity puts the incoming scene in its scene list and drops the
    // old one when the new one activates, so more than one scene in the list
    // is a load in flight. The pause menu is the exception: StaticPauseScene
    // (build index 2) loads additively and isn't a load.
    //
    // This 60 Hz reading is the fallback; PRECISE LOADS (init) is the real one
    // whenever its thread is running. Both count scenes other than the pause
    // menu, so a quit from the pause menu (pause, old, new: three scenes) is
    // a load from its first instant.
    vars.LoadingOld = vars.Loading;
    bool loading = false;
    bool pausePresent = false;
    if (vars.HelperReady)
    {
        try
        {
            int count = vars.Helper.Scenes.Count;
            if (count > 1)
            {
                foreach (var sc in vars.Helper.Scenes.Loaded)
                {
                    if (sc.Index == 2) { pausePresent = true; break; }
                }
                loading = count - (pausePresent ? 1 : 0) > 1;
            }
        }
        catch (Exception e)
        {
            loading = false;
            if (!vars.LoadErrLogged) { vars.TLog("scene count read failed, loads not removed: " + e.Message); vars.LoadErrLogged = true; }
        }
    }
    vars.Loading = loading;
    if (loading && !vars.LoadingOld)
    {
        vars.LoadStartedAt = DateTime.Now;
        vars.TLog("load began");
    }
    else if (!loading && vars.LoadingOld)
    {
        vars.TLog("load ended after " + (DateTime.Now - (DateTime)vars.LoadStartedAt).TotalSeconds.ToString("0.000") + " s (60 Hz reading)");
    }

    // The precise spans. Each queued event is one scene-count change:
    // {time, new count, old count, frame, end}, end being the third frame
    // tick after a drop. I judge the pause menu with this tick's scene list,
    // which is safe because the pause scene is never added or removed in the
    // same instant as a load's own scenes.
    if (vars.PreciseLoads && vars.HelperReady)
    {
        var q = (System.Collections.Concurrent.ConcurrentQueue<long[]>)vars.LoadEvents;
        long[] ev;
        while (q.TryDequeue(out ev))
        {
            int nonPause = (int)ev[1] - (pausePresent ? 1 : 0);
            if (!vars.InLoad && nonPause > 1)
            {
                vars.InLoad = true;
                vars.LoadFrom = ev[0];
            }
            else if (vars.InLoad && nonPause <= 1)
            {
                vars.InLoad = false;
                long from = vars.LoadFrom, to = ev[4];
                vars.Spans.Add(new long[] { from, to });
                vars.TLog("load " + new DateTime(from).ToString("HH:mm:ss.fff") + " to " + new DateTime(to).ToString("HH:mm:ss.fff")
                        + " = " + ((to - from) / (double)TimeSpan.TicksPerSecond).ToString("0.000") + " s (precise)");
                if (!vars.StatsLogged)
                {
                    vars.StatsLogged = true;
                    long[] st = vars.LoadStats;
                    vars.TLog("load thread polls every " + (st[1] / (double)Math.Max(1L, st[0]) / TimeSpan.TicksPerMillisecond).ToString("0.00") + " ms on average");
                }
            }
        }
    }

    // TITLE CARD WATCH. After the blue, nothing in the UI changes until the
    // title card Image switches on, which adds one graphic to a canvas that
    // already exists, in the same frame its fade begins. Twenty seconds after
    // the blue (the title comes at about 28 s), I hand every canvas's graphic
    // list to the load thread with its size, and the first one to grow is the
    // title. I give up 40 s after the blue: a checkpoint warp writes the blue
    // before its own load, so the title comes later than in a run. The pause
    // menu brings its own canvas, which isn't on the list; if the game is
    // paused anyway, the watch is withdrawn and taken again on unpause.
    if (vars.PreciseLoads && vars.BlueAt != null && !vars.TitleDone)
    {
        var tw = (object[])vars.TitleWatch;
        if (vars.TitleArmed && pausePresent)
        {
            tw[0] = null;
            vars.TitleArmed = false;
            vars.TLog("paused during the blue ride: title watch withdrawn until unpaused");
        }
        else if (!vars.TitleArmed && !pausePresent && vars.HelperReady
                 && DateTime.Now >= ((DateTime)vars.BlueAt).AddSeconds(20))
        {
            List<long[]> snap = vars.CanvasLists();
            if (snap.Count > 0)
            {
                var lists = new IntPtr[snap.Count];
                var sizes = new int[snap.Count];
                for (int i = 0; i < snap.Count; i++) { lists[i] = new IntPtr(snap[i][0]); sizes[i] = (int)snap[i][1]; }
                tw[3] = 0L;
                tw[1] = sizes;
                tw[0] = lists;
                vars.TitleArmed = true;
                vars.TLog("title watch armed on " + snap.Count + " canvases");
            }
        }
    }

    vars.Wrote = false;
    vars.NewLevel = null;
    vars.NewSub = null;
    string oldTime = vars.Time;
    int oldScene = vars.Scene;
    // A failed or torn read still returns true, so reset runs this tick and
    // can't miss the one tick the menu edge is visible on.
    if (!vars.ReadPrefs()) return true;

    // The Cave saves no flag. CaveSceneProgression.Awake calls
    // StoreSceneAsSceneCheckpoint and never sets a progress flag, so no stamp
    // moves and the stamp rule below never sees it: the registry goes from
    // 8:5 straight to 12:0. Scene 11 appearing without a new stamp is
    // entering the Cave, which ends Second Cabin (part 2). It's safe from
    // torn reads because no flag write ever follows it.
    if (vars.Scene == 11 && oldScene != 11 && oldScene != -1 && vars.Time == oldTime)
    {
        vars.NewLevel = "Cave";
        vars.NewSub = "11:0";
        // From here the Cave is the scene of record for the fallback start's
        // "did the scene move" test.
        vars.SceneAtStamp = 11;
        vars.TLog("scene write 11 (no flag) -> Cave");
        return true;
    }

    // Every flag write stamps CheckpointTime, even a rewrite of the same flag,
    // so a changed stamp means "the game just saved a checkpoint". init took
    // the baseline; on a brand-new save it is "", so the very first write
    // ever (New Game) still counts.
    if (vars.Time == oldTime) return true;

    vars.Wrote = true;

    // The scene as of the previous stamp, for start's New Game test. I take
    // it from stamps rather than the last read, because a read can land
    // between scene select's scene write and its flag write and make the
    // scene look unchanged. -1 means no earlier stamp (a brand-new save).
    vars.SceneBefore = vars.SceneAtStamp;
    vars.SceneAtStamp = vars.Scene;
    vars.NewLevel = vars.LevelOf(vars.Scene, vars.Flag);
    string key = vars.Scene + ":" + vars.Flag;
    vars.NewSub = vars.SubKeys.Contains(key) ? key : null;
    // How late this poll saw the write: the stamp is DateTime.Now.Ticks at
    // the moment the game saved it.
    long stampTicks;
    string lag = long.TryParse((string)vars.Time, out stampTicks)
        ? ((DateTime.Now - new DateTime(stampTicks)).TotalMilliseconds.ToString("0") + " ms after stamp "
           + new DateTime(stampTicks).ToString("HH:mm:ss.fff"))
        : "stamp unreadable";
    vars.TLog("checkpoint write " + key
           + " -> " + (vars.NewLevel ?? "(inside current level)")
           + ", seen " + lag + ", menu=" + vars.OnMenu + ", sceneOk=" + vars.SceneOk);

    // The final split is the title card, not the blue. Epilogue flag 2 is the
    // blue; the title card fades in about 28 s later, after a scene trigger
    // (EndCameraCut), 8.0 s, the credits starting, and 2.0 s. With the load
    // thread I watch for the title card itself (TITLE CARD WATCH); without
    // it, the split comes a fixed delay after the blue write's own stamp.
    // Pausing during the blue ride would make that fixed delay split early.
    if (vars.NewLevel == "END")
    {
        vars.NewLevel = null;
        // Any run that reaches the blue arms the final split, whatever level
        // the script thinks it's in, so warps and partial runs work too.
        if (vars.EndAt == null)
        {
            vars.BlueAt = new DateTime(stampTicks);
            // With the load thread, EndAt is only the give-up point; without
            // it, EndAt is the fixed-delay split itself.
            vars.EndAt = ((DateTime)vars.BlueAt).AddSeconds(vars.PreciseLoads ? 40.0 : (double)vars.EndDelay);
            vars.TLog("blue reached: " + (vars.PreciseLoads ? "watching for the title card"
                : "final split scheduled for " + ((DateTime)vars.EndAt).ToString("HH:mm:ss.fff")));
        }
    }

    // A click start waits for proof it was New Game: flag 0, from the menu,
    // at least 10 s after the click (the intro is 11.0 s; scene select writes
    // in the same frame as its click). Anything else written while waiting
    // means the click wasn't New Game. Timing alone decides it, because the
    // scene value can't be trusted here: after quitting from the Cave, whose
    // scene write carries no stamp, New Game's write looks like a scene move.
    if (vars.Pending)
    {
        double gap = (new DateTime(stampTicks) - vars.PendingSince).TotalSeconds;
        if (vars.Flag == 0 && vars.OnMenu && gap >= 10.0)
        {
            vars.Pending = false;
            vars.TLog("New Game confirmed: click to first write " + gap.ToString("0.000") + " s");

            // Only for a click timed by the 60 Hz tick: the real click was
            // at least 11.0 s before this write's stamp, so pull the start
            // back until the timer read 11.0 s at the stamp. Capped at half
            // a second as a sanity bound.
            double stampAgo = (DateTime.Now - new DateTime(stampTicks)).TotalSeconds;
            double atStamp = timer.CurrentTime.RealTime.Value.TotalSeconds - stampAgo;
            double shift = 11.0 - atStamp;
            // A thread-timed click is already the real moment (CLICK TIMING).
            if (!vars.ClickPrecise && shift > 0 && shift < 0.5)
            {
                TimeSpan back = TimeSpan.FromSeconds(shift);
                timer.AdjustedStartTime   = timer.AdjustedStartTime - back;
                timer.StartTimeWithOffset = timer.StartTimeWithOffset - back;
                timer.StartTime           = timer.StartTime - back;
                vars.TLog("start pulled back " + (shift * 1000).ToString("0") + " ms to the intro's 11.0 s");
            }
        }
        else
        {
            vars.CancelStart = true;
            vars.TLog("click was not New Game (write " + gap.ToString("0.000") + " s after it): cancelling start");
        }
    }
}

start
{
    // The run starts on "Yes" itself.
    //
    // Primary: start on the click (see THE CLICK in init). The click could be
    // Continue, scene select or brightness rather than Yes, so the start is
    // provisional until the New Game write proves it; update cancels it
    // otherwise and reset carries the cancel out.
    //
    // Fallback, when the click read isn't available: Yes starts
    // MainMenuSceneController.NewGameCoroutine, 1.5 + 2 + 0.5 + 4 + 3 = 11.0 s
    // of waits, then SceneLoader.OnNewGame writes flag 0 with the menu still
    // active. Start on that write and backdate 11.0 s from its stamp. Scene
    // select (and IL mods) also write flag 0 from the menu, but they set the
    // scene first; New Game never touches it. The one blind spot of this path
    // is scene-selecting the level the save already sits in.
    vars.Backdate = false;
    vars.ClickStart = false;

    if (vars.ClickEdge)
    {
        vars.ClickStart = true;
        return true;
    }

    if (!vars.Wrote || vars.Flag != 0) return false;

    if (vars.SceneOk)
    {
        if (!vars.OnMenu) return false;
        if (vars.SceneBefore != -1 && vars.Scene != vars.SceneBefore)
        {
            vars.TLog("flag 0 written from the menu with a new scene: scene select, not New Game");
            return false;
        }
        vars.Backdate = true;
        return true;
    }

    // No working scene read at all: start at the Opening checkpoint, about six
    // seconds after the intro. Late, but a start.
    return vars.Scene == 4;
}

onStart
{
    // Spans from before this run never count; a load already in flight does.
    if (((IDictionary<string, object>)vars).ContainsKey("Spans")) vars.Spans.Clear();
    vars.EndAt = null;
    vars.FixSplitTo = null;
    vars.BlueAt = null;
    vars.TitleArmed = false;
    vars.TitleDone = false;
    if (((IDictionary<string, object>)vars).ContainsKey("TitleWatch")) { var twS = (object[])vars.TitleWatch; twS[0] = null; twS[3] = 0L; }

    if (vars.ClickStart)
    {
        // Pull the start back to the click itself. I measure from LiveSplit's
        // own start stamp (now minus the timer's reading) rather than from
        // "now": other OnStart handlers may run before this one, and "now"
        // would pull the start back too far.
        long lsStart = (long)vars.Now() - timer.CurrentTime.RealTime.Value.Ticks;
        TimeSpan since = TimeSpan.FromTicks(lsStart - ((DateTime)vars.ClickAt).Ticks);
        if (since < TimeSpan.Zero || since > TimeSpan.FromSeconds(1)) since = TimeSpan.Zero;
        timer.AdjustedStartTime   = timer.AdjustedStartTime - since;
        timer.StartTimeWithOffset = timer.StartTimeWithOffset - since;
        timer.StartTime           = timer.StartTime - since;
        vars.Pending = true;
        vars.PendingSince = vars.ClickAt;
        vars.CancelStart = false;
        vars.TLog("started on menu click, waiting for New Game to confirm");
    }

    // Fallback path: backdate to the Yes press. The stamp is
    // DateTime.Now.Ticks at the write, so the poll delay is measured, and
    // 11.0 s is the coroutine's waits. Each WaitForSeconds resumes on the
    // first frame past its time, so the true gap runs a few frames over.
    if (vars.Backdate)
    {
        long ticks;
        if (long.TryParse((string)vars.Time, out ticks))
        {
            TimeSpan since = DateTime.Now - new DateTime(ticks);
            if (since < TimeSpan.Zero || since > TimeSpan.FromSeconds(2)) since = TimeSpan.Zero;
            TimeSpan back = TimeSpan.FromSeconds(11.0) + since;
            timer.AdjustedStartTime   = timer.AdjustedStartTime - back;
            timer.StartTimeWithOffset = timer.StartTimeWithOffset - back;
            timer.StartTime           = timer.StartTime - back;
            vars.TLog("started on the New Game write: backdated " + back.TotalSeconds.ToString("0.000")
                   + " s, timer now reads " + timer.CurrentTime.RealTime);
        }
    }

    vars.Level = "Opening";
    vars.Entered.Clear();
    vars.Entered.Add("Opening");
    vars.Sub = "4:0";
    vars.EnteredSubs.Clear();
    vars.EnteredSubs.Add("4:0");
}

onReset
{
    // A manual reset during a provisional start drops it too.
    vars.Pending = false;
    vars.CancelStart = false;
    vars.EndAt = null;
    vars.FixSplitTo = null;
    vars.BlueAt = null;
    vars.TitleArmed = false;
    vars.TitleDone = false;
    if (((IDictionary<string, object>)vars).ContainsKey("TitleWatch")) { var twR = (object[])vars.TitleWatch; twR[0] = null; twR[3] = 0L; }
}

split
{
    // The final split: the title card as the load thread saw it, or the
    // fixed delay if it was never seen.
    var twSplit = (object[])vars.TitleWatch;
    bool titleSeen = vars.EndAt != null && vars.PreciseLoads && (long)twSplit[3] != 0L;
    if (vars.EndAt != null && (titleSeen || DateTime.Now >= (DateTime)vars.EndAt))
    {
        if (titleSeen)
        {
            vars.FixSplitTo = new DateTime((long)twSplit[3]);
            vars.TLog("title card switched on at " + new DateTime((long)twSplit[2]).ToString("HH:mm:ss.fff")
                    + ", next frame " + ((DateTime)vars.FixSplitTo).ToString("HH:mm:ss.fff")
                    + " (" + ((DateTime)vars.FixSplitTo - (DateTime)vars.BlueAt).TotalSeconds.ToString("0.000") + " s after the blue)");
        }
        else
        {
            vars.FixSplitTo = ((DateTime)vars.BlueAt).AddSeconds(vars.EndDelay);
            if (vars.PreciseLoads) vars.TLog("title card NOT seen by 40 s after the blue: fixed delay used");
        }
        twSplit[0] = null;
        twSplit[3] = 0L;
        vars.TitleArmed = false;
        vars.TitleDone = true;
        vars.EndAt = null;
        vars.Entered.Add("END");
        vars.Level = "END";
        vars.TLog("level ended: Epilogue (title card)");
        if (settings["Epilogue"]) { vars.TLog("SPLIT requested"); return true; }
        vars.FixSplitTo = null;
        return false;
    }

    // Split once per level and once per subscene, on first entry. A death or
    // a checkpoint reload rewrites a checkpoint without the run advancing, and
    // a warp back to an earlier level mustn't split again when the run plays
    // forward out of it. A splitter that fires twice turns one mistake into a
    // broken run.
    //
    // Both are checked every time, so a checkpoint that ends a subscene and a
    // level together still fires exactly one split.
    // Nothing written from the main menu is a split: the New Game write
    // carries the old save's scene with flag 0, which would otherwise look
    // like entering some level mid-game.
    if (vars.SceneOk && vars.OnMenu) return false;

    bool fire = false;

    string nextLevel = vars.NewLevel;
    if (nextLevel != null && vars.Entered.Add(nextLevel))
    {
        string ended = vars.Level;
        vars.Level = nextLevel;
        vars.TLog("level ended: " + ended);
        if (ended != null && settings[ended]) fire = true;
    }

    string nextSub = vars.NewSub;
    if (nextSub != null && vars.EnteredSubs.Add(nextSub))
    {
        string endedSub = vars.Sub;
        vars.Sub = nextSub;
        if (endedSub != null && settings["sub:" + endedSub]) fire = true;
    }

    if (fire) vars.TLog("SPLIT requested");
    return fire;
}

onSplit
{
    // Logs what LiveSplit actually did with each split, by segment name, so
    // a missing split can be checked against the splits file.
    int i = timer.CurrentSplitIndex;
    string closed = i >= 1 && i - 1 < timer.Run.Count ? timer.Run[i - 1].Name : "?";

    // Exact split times. LiveSplit holds Game Time at the value gameTime gave
    // earlier in the same tick, while real time keeps running until the split
    // lands, so the recorded LRT would come out a little short. And this
    // handler runs after LiveSplit stamped the split (and after any other
    // OnSplit handlers), so correcting by "now" would take off too much. So I
    // write both from absolutes on vars.Now's clock: real = moment minus run
    // start, and game = real minus the load time removed up to that moment.
    if (vars.PreciseLoads && (long)vars.RunStartAbs != 0L && i >= 1 && i - 1 < timer.Run.Count
        && timer.Run[i - 1].SplitTime.RealTime != null)
    {
        var seg = timer.Run[i - 1];
        long runStart = vars.RunStartAbs;
        TimeSpan real = seg.SplitTime.RealTime.Value;
        if (vars.FixSplitTo != null)
        {
            TimeSpan exact = TimeSpan.FromTicks(((DateTime)vars.FixSplitTo).Ticks - runStart);
            TimeSpan late = real - exact;
            if (exact > TimeSpan.Zero && late > TimeSpan.Zero && late < TimeSpan.FromSeconds(5))
            {
                real = exact;
                vars.TLog("final split set to the title moment, " + late.TotalMilliseconds.ToString("0") + " ms before LiveSplit's stamp");
            }
        }
        long removedAt = vars.RemovedUpTo(runStart, runStart + real.Ticks);
        seg.SplitTime = new Time(real, real - TimeSpan.FromTicks(removedAt));
        vars.FixSplitTo = null;
    }

    // Without the load thread: correct the final split by "now".
    if (vars.FixSplitTo != null && i >= 1 && i - 1 < timer.Run.Count)
    {
        var seg = timer.Run[i - 1];
        if (seg.SplitTime.RealTime != null)
        {
            TimeSpan late = new DateTime((long)vars.Now()) - (DateTime)vars.FixSplitTo;
            if (late > TimeSpan.Zero && late < TimeSpan.FromSeconds(5))
            {
                // Game Time too: the title card is never inside a load, so
                // both clocks were running in that gap.
                TimeSpan? gt = seg.SplitTime.GameTime;
                seg.SplitTime = new Time(seg.SplitTime.RealTime.Value - late, gt.HasValue ? gt.Value - late : gt);
                vars.TLog("final split corrected " + late.TotalMilliseconds.ToString("0") + " ms earlier, to the scheduled moment");
            }
        }
        vars.FixSplitTo = null;
    }
    vars.TLog("LiveSplit split: closed segment " + i + " '" + closed + "' at " + timer.CurrentTime.RealTime);
    if (i >= 1 && i - 1 < timer.Run.Count)
    {
        var st = timer.Run[i - 1].SplitTime;
        vars.TLog("  recorded: real " + st.RealTime + ", game (LRT) " + st.GameTime);
    }
}

reset
{
    // A provisional click start that turned out not to be New Game.
    if (vars.CancelStart)
    {
        vars.CancelStart = false;
        vars.Pending = false;
        return true;
    }

    // Reset on arriving at the main menu, and only mid-run: a finished run
    // must survive the trip back to the menu after the credits.
    if (!vars.HasHelper || !settings["menuReset"]) return false;
    if (timer.CurrentPhase != TimerPhase.Running) return false;
    if (vars.OnMenu && !vars.OnMenuOld)
    {
        vars.TLog("quit to menu: reset");
        return true;
    }
    return false;
}

isLoading
{
    // Game Time is Loads Removed Time. With the precise thread running,
    // LiveSplit's own game clock is held and gameTime supplies the value;
    // otherwise LiveSplit pauses on the 60 Hz reading.
    return vars.PreciseLoads ? true : vars.Loading;
}

gameTime
{
    // Real time minus every precise load span inside this run, plus the load
    // in flight, all on vars.Now's clock, so loads come off to the
    // millisecond.
    if (!vars.PreciseLoads || timer.CurrentTime.RealTime == null) return null;
    long now = vars.Now();
    TimeSpan real = timer.CurrentTime.RealTime.Value;
    long runStart = now - real.Ticks;
    // The run's start on vars.Now's clock, for onSplit to write exact times.
    vars.RunStartAbs = runStart;
    long removed = vars.RemovedUpTo(runStart, now);
    return real - TimeSpan.FromTicks(removed);
}

exit
{
    // The game closed. A read in flight at that moment can throw "the handle
    // is invalid" once; that's the close, not a bug.
    vars.TLog("game closed");

    // A provisional click start whose click was the menu's Quit button can
    // never be confirmed or cancelled by the game, so I undo it here. A
    // confirmed run is left alone so a crash doesn't cost the run.
    if (vars.Pending)
    {
        vars.Pending = false;
        vars.CancelStart = false;
        vars.TLog("game closed during a provisional start: resetting");
        new TimerModel { CurrentState = timer }.Reset();
    }

    // What asl-help's generated code would do on exit, then back to slow
    // ticks for the next attach's wait.
    if (vars.HasHelper) vars.Helper.Dispose();
    ((bool[])vars.LoadStop)[0] = true;
    refreshRate = 4;
}

shutdown
{
    if (vars.HasHelper) vars.Helper.Dispose();
    // The load thread only exists once init has run.
    var d = (IDictionary<string, object>)vars;
    if (d.ContainsKey("LoadStop")) ((bool[])vars.LoadStop)[0] = true;
}

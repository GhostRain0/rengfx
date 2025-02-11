/** globally available game core, providing access to most key game services and scene control */

module re.core;

import std.array;
import std.typecons;
import std.format;

import re.input;
import re.content;
import re.time;
import re.gfx.window;
import re.ng.scene;
import re.ng.diag;
import re.ng.manager;
import re.gfx.render_ext;
import re.math;
import re.util.logger;
import re.util.tweens.tween_manager;
import jar;
static import raylib;

/**
Core class
*/
abstract class Core {
    /// logger utility
    public static Logger log;

    /// game window
    public static Window window;

    /// content manager
    public static ContentManager content;

    /// the current scenes
    private static Scene[] _scenes;

    /// type registration container
    public static Jar jar;

    /// global managers
    public static Manager[] managers;

    /// whether to draw debug information
    public static bool debug_render;

    /// debugger utility
    debug public static Debugger debugger;

    /// whether the game is running
    public static bool running;

    version (unittest) {
        /// the frame limit (used for testing)
        public static int frame_limit = 60;
    }

    /// target frames per second
    public static int target_fps = 60;

    /// whether graphics should be disabled
    public static bool headless = false;

    /// whether to pause when unfocused
    public static bool pause_on_focus_lost = true;

    /// whether to exit when escape pressed
    public static bool exit_on_escape_pressed = true;

    /// oversampling factor for internal rendering
    public static int render_oversample = 1;

    /// whether to automatically scale things to compensate for hidpi
    /// NOTE: raylib.ConfigFlags.FLAG_WINDOW_HIGHDPI also exists, but we're not using it right now
    public static bool auto_compensate_hidpi = true;

    /// whether to automatically oversample for hidpi
    public static bool auto_oversample_hidpi = false;

    /// whether to rescale the mouse position to compensate for hidpi
    public static bool auto_rescale_mouse_hidpi = false;

    /// whether to automatically resize the render target to the window size
    public static bool sync_render_window_resolution = false;

    /// the default render resolution for all scenes
    public static Vector2 default_resolution;

    /// the default texture filtering mode for render targets
    public static raylib.TextureFilter default_filter_mode
        = raylib.TextureFilter.TEXTURE_FILTER_POINT;

    version (vr) {
        import re.gfx.vr;

        public static VRSupport vr;
    }

    /// sets up a game core
    this(int width, int height, string title) {
        log = Logger(Verbosity.info);

        version (unittest) {
        } else {
            log.info("initializing rengfx core");
        }

        default_resolution = Vector2(width, height);
        if (!Core.headless) {
            window = new Window(width, height);
            window.initialize();
            window.set_title(title);
            if (auto_compensate_hidpi) {
                handle_hidpi_compensation();
            }
        }

        // disable default exit key
        raylib.SetExitKey(raylib.KeyboardKey.KEY_NULL);

        content = new ContentManager();

        jar = new Jar();

        add_manager(new TweenManager());

        debug {
            debugger = new Debugger();
        }

        version (vr) {
            import re.gfx.vr;

            vr = new VRSupport();
        }

        version (unittest) {
        } else {
            log.info("initializing game");
        }

        initialize();
    }

    @property public static int fps() {
        return raylib.GetFPS();
    }

    /// sets up the game
    abstract void initialize();

    /// starts the game
    public void run() {
        running = true;
        // start the game loop
        while (running) {
            if (!headless) {
                running = !raylib.WindowShouldClose();
            }

            update();
            draw();

            version (unittest) {
                if (Time.frame_count >= frame_limit) {
                    running = false;
                }
            }
        }
    }

    /// gracefully exits the game
    public static void exit() {
        running = false;
        version (unittest) {
        } else {
            log.info("gracefully exiting");
        }
    }

    protected void update() {
        // update window
        if (!Core.headless) {
            if (pause_on_focus_lost && raylib.IsWindowMinimized()) {
                return; // pause
            }
            if (exit_on_escape_pressed && raylib.IsKeyPressed(raylib.KeyboardKey.KEY_ESCAPE)) {
                exit();
            }
            if (raylib.IsWindowResized()) {
                handle_window_resize();
            }
        }

        version (unittest) {
            Time.update(1f / target_fps); // 60 fps
        } else {
            Time.update(raylib.GetFrameTime());
        }
        foreach (manager; managers) {
            manager.update();
        }
        // update input
        Input.update();
        // update scenes
        foreach (scene; _scenes) {
            scene.update();
        }
        debug {
            debugger.update();
        }
    }

    protected void draw() {
        if (Core.headless)
            return;
        if (raylib.IsWindowMinimized()) {
            return; // suppress draw
        }
        raylib.BeginDrawing();
        foreach (scene; _scenes) {
            // render scene
            scene.render();
            // post-render
            scene.post_render();
            // composite  (blit)screen render to window
            // when the scene is rendered, it is rendered to a texture. this texture is then composited onto the main display buffer.

            version (vr) {
                bool vr_distort = false;
                if (vr.enabled) {
                    assert(vr.distortion_shader != raylib.Shader.init, "vr.distortion_shader is not initialized");
                    vr_distort = true;
                }

                if (vr_distort)
                    raylib.BeginShaderMode(vr.distortion_shader);
            }

            RenderExt.draw_render_target(scene.render_target, Rectangle(0, 0,
                    window.width, window.height), scene.composite_mode.color);

            version (vr) {
                if (vr_distort)
                    raylib.EndShaderMode();
            }
        }
        debug {
            debugger.render();
        }
        raylib.EndDrawing();
    }

    public static T get_scene(T)() {
        import std.algorithm.searching : find;

        // find a scene matching the type
        auto matches = _scenes.find!(x => (cast(T) x) !is null);
        assert(matches.length > 0, "no matching scene was found");
        return cast(T) matches.front;
    }

    public static Nullable!T get_manager(T)() {
        import std.algorithm.searching : find;

        // find a manager matching the type
        auto matches = managers.find!(x => (cast(T) x) !is null);
        if (matches.length > 0) {
            return Nullable!T(cast(T) matches.front);
        }
        return Nullable!T.init;
    }

    /// adds a global manager
    public T add_manager(T)(T manager) {
        managers ~= manager;
        manager.setup();
        return manager;
    }

    @property public static Scene[] scenes() {
        return _scenes;
    }

    @property public static Scene primary_scene() {
        return _scenes.front;
    }

    /// sets the current scenes
    static void load_scenes(Scene[] new_scenes) {
        foreach (scene; _scenes) {
            // end old scenes
            scene.end();
            scene = null;
        }
        // clear scenes list
        _scenes = [];

        _scenes ~= new_scenes;
        // begin new scenes
        foreach (scene; _scenes) {
            scene.begin();
        }
    }

    /// releases all resources and cleans up
    public void destroy() {
        version (vr) {
            if (vr.enabled) {
                assert(vr.config != raylib.VrStereoConfig.init, "vr config was not initialized");

                raylib.UnloadVrStereoConfig(vr.config);
            }

        }
        debug {
            debugger.destroy();
        }
        content.destroy();
        load_scenes([]); // end scenes
        foreach (manager; managers) {
            manager.destroy();
        }
        if (!Core.headless) {
            window.destroy();
        }
    }

    private void handle_hidpi_compensation() {
        // when hidpi is enabled,, the window is too small
        // so we scale the real window but keep the render resolution the same
        // compute the target window size
        auto scaled_width = window.width_dpi;
        auto scaled_height = window.height_dpi;
        // but, if auto-oversampling is enabled, we need to set the oversample factor
        if (auto_oversample_hidpi) {
            render_oversample = cast(int) window.scale_dpi;
            log.info("auto-oversampling enabled, setting oversample factor to %d", render_oversample);
        }
        log.info("resizing window from (%s,%s) to (%s,%s) to compensate for dpi scale: %s",
            window.width, window.height, scaled_width, scaled_height, window.scale_dpi);
        window.resize(scaled_width, scaled_height);
        handle_window_resize();
        sync_render_resolution();
        if (auto_rescale_mouse_hidpi) {
            // set mouse transform to compensate for dpi scale
            raylib.SetMouseScale(1 / window.scale_dpi, 1 / window.scale_dpi);
        }
    }

    private void handle_window_resize() {
        log.info("window resized to (%s,%s)", window.width, window.height);
        // window was resized
        if (sync_render_window_resolution) {
            sync_render_resolution();
        }
        // notify the active scenes
        foreach (scene; _scenes) {
            scene.on_window_resized();
        }
    }

    private void sync_render_resolution() {
        // since window was resized, update our render resolution
        // first get the new window size
        auto render_res_x = window.width;
        auto render_res_y = window.height;
        // if (auto_compensate_hidpi) {
        //     // if hidpi compensation is enabled, we need to scale the window size by the hidpi scale
        //     render_res_x = cast(int)(render_res_x / window.scale_dpi);
        //     render_res_y = cast(int)(render_res_y / window.scale_dpi);
        //     // if hidpi compensation is on then the window size will be scale*resolution
        //     // so we need to divide by the scale to get the render resolution
        // }
        // if oversampling is enabled, we need to multiply by the oversampling factor
        render_res_x *= render_oversample;
        render_res_y *= render_oversample;
        // set the render resolution
        default_resolution = Vector2(render_res_x, render_res_y);
        // Core.log.info(format("updating render resolution to %s", default_resolution));
        Core.log.info(format("updating render resolution to %s (dpi scale %s) (oversample %s)",
                default_resolution, window.scale_dpi, render_oversample));
    }
}

@("core-basic")
unittest {
    import re.util.test : TestGame;
    import std.string : format;
    import std.math : isClose;

    class Game : TestGame {
        override void initialize() {
            // nothing much
        }
    }

    auto game = new Game();
    game.run();

    // ensure time has passed
    auto target_time = Core.frame_limit / Core.target_fps;
    assert(isClose(Time.total_time, target_time),
        format("time did not pass (expected: %s, actual: %s)", target_time, Time.total_time));

    game.destroy(); // clean up

    assert(game.scenes.length == 0, "scenes were not removed after Game cleanup");
}

/*
 * waxco: lets Lua create coroutines that UE4SS will accept engine calls from.
 *
 * Every UE4SS function, property access and UFunction call starts by looking the calling lua_State up in
 * UE4SS's own table of known Lua threads. A coroutine made with coroutine.create is not in that table, so
 * every engine call inside one fails with "has no instance inside lua_instances unordered map".
 * UE4SS creates its own extra threads with RC::LuaMadeSimple::Lua::new_thread(), which makes the thread AND
 * adds it to that table, and UE4SS.dll exports that function. This helper calls it.
 *
 * UE4SS.dll does not export the Lua C API, so this file cannot call lua_* functions. It needs none:
 *   - new_thread() leaves the new thread on the caller's stack, which is the return value;
 *   - the function the coroutine should run is parked by the Lua side in the registry under WAX_FN_KEY,
 *     and Lua::rawgeti() on the NEW thread's wrapper pushes it onto the new thread's stack.
 *
 * Lua side (see wax/core/co.lua):
 *     registry[WAX_FN_KEY] = fn;  local co = wax_newthread();  registry[WAX_FN_KEY] = nil
 *
 * Each exported function is fetched with package.loadlib(path, "<name>"), which returns it as a Lua C function.
 * Built with plain C and no C runtime use beyond kernel32, tied to the UE4SS build named in tools.json.
 */
#include <windows.h>

typedef struct lua_State lua_State;

/* luaconf.h of this UE4SS build: LUAI_MAXSTACK 1000000, LUA_REGISTRYINDEX (-LUAI_MAXSTACK - 1000). */
#define LUA_REGISTRYINDEX (-1000000 - 1000)
#define LUA_TFUNCTION 6
/* Negative, so it can never collide with the positive slots luaL_ref hands out. Keep in sync with co.lua. */
#define WAX_FN_KEY (-22433LL)
#define WAX_NATIVE_VERSION 1

/* RC::LuaMadeSimple::Lua members. On x64 a member function is an ordinary call with `this` first. */
typedef void *(*lua_ctor_t)(void *self, lua_State *state);
typedef void (*lua_dtor_t)(void *self);
typedef void *(*lua_new_thread_t)(const void *self);
typedef int (*lua_rawgeti_t)(const void *self, int index, long long n);
typedef void (*lua_discard_value_t)(const void *self, int index);
typedef void (*lua_set_integer_t)(const void *self, long long value);

static lua_ctor_t lua_ctor;
static lua_dtor_t lua_dtor;
static lua_new_thread_t lua_new_thread;
static lua_rawgeti_t lua_rawgeti;
static lua_discard_value_t lua_discard_value;
static lua_set_integer_t lua_set_integer;
static int resolved; /* 0 = not tried, 1 = ok, -1 = failed */

static int resolve(void)
{
    HMODULE ue4ss;
    if (resolved) return resolved > 0;
    resolved = -1;
    ue4ss = GetModuleHandleA("UE4SS.dll");
    if (!ue4ss) return 0;
    lua_ctor = (lua_ctor_t)GetProcAddress(ue4ss, "??0Lua@LuaMadeSimple@RC@@QEAA@PEAUlua_State@@@Z");
    lua_dtor = (lua_dtor_t)GetProcAddress(ue4ss, "??1Lua@LuaMadeSimple@RC@@QEAA@XZ");
    lua_new_thread = (lua_new_thread_t)GetProcAddress(ue4ss, "?new_thread@Lua@LuaMadeSimple@RC@@QEBAAEAV123@XZ");
    lua_rawgeti = (lua_rawgeti_t)GetProcAddress(ue4ss, "?rawgeti@Lua@LuaMadeSimple@RC@@QEBAHH_J@Z");
    lua_discard_value = (lua_discard_value_t)GetProcAddress(ue4ss, "?discard_value@Lua@LuaMadeSimple@RC@@QEBAXH@Z");
    lua_set_integer = (lua_set_integer_t)GetProcAddress(ue4ss, "?set_integer@Lua@LuaMadeSimple@RC@@QEBAX_J@Z");
    if (lua_ctor && lua_dtor && lua_new_thread && lua_rawgeti && lua_discard_value && lua_set_integer) resolved = 1;
    return resolved > 0;
}

/*
 * Room for one RC::LuaMadeSimple::Lua. Its real size is well under 2 KB (a pointer, a vector, a string_view,
 * six optional std::function and a reference); the constructor only writes inside that.
 */
typedef struct { _Alignas(16) unsigned char bytes[16384]; } lua_wrapper_storage;

/* wax_native_version() -> integer, or nothing if UE4SS's exports could not be found. */
__declspec(dllexport) int wax_native_version(lua_State *L)
{
    lua_wrapper_storage here;
    if (!resolve()) return 0;
    lua_ctor(&here, L);
    lua_set_integer(&here, WAX_NATIVE_VERSION); /* lua_pushinteger on L */
    lua_dtor(&here);
    return 1;
}

/* wax_clock_us() -> integer microseconds from the high-resolution counter (os.clock only resolves 1 ms here). */
__declspec(dllexport) int wax_clock_us(lua_State *L)
{
    lua_wrapper_storage here;
    LARGE_INTEGER now, frequency;
    if (!resolve()) return 0;
    QueryPerformanceCounter(&now);
    QueryPerformanceFrequency(&frequency);
    lua_ctor(&here, L);
    lua_set_integer(&here, (now.QuadPart / frequency.QuadPart) * 1000000LL
                               + (now.QuadPart % frequency.QuadPart) * 1000000LL / frequency.QuadPart);
    lua_dtor(&here);
    return 1;
}

/*
 * wax_newthread() -> thread, or nothing on failure.
 * The new thread is registered with UE4SS and has registry[WAX_FN_KEY] on its stack, ready for coroutine.resume.
 */
__declspec(dllexport) int wax_newthread(lua_State *L)
{
    lua_wrapper_storage here;
    void *thread;
    if (!resolve()) return 0;
    lua_ctor(&here, L);
    thread = lua_new_thread(&here); /* lua_newthread(L): the thread is now on top of L's stack */
    if (lua_rawgeti(thread, LUA_REGISTRYINDEX, WAX_FN_KEY) != LUA_TFUNCTION) {
        lua_discard_value(thread, -1); /* leave the thread empty: Lua then sees a dead coroutine */
        lua_dtor(&here);
        return 0;
    }
    lua_dtor(&here);
    return 1;
}

// SPDX-License-Identifier: GPL-3.0-or-later
#include "TrigITCore.h"
#include "EmbeddedLua.h"

#include <atomic>
#include <chrono>
#include <fstream>
#include <mutex>
#include <sstream>
#include <thread>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
}

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET Socket;
typedef int socklen_t;
static const Socket NO_SOCKET = INVALID_SOCKET;
static void closeSocket( Socket s ) { closesocket( s ); }
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
typedef int Socket;
static const Socket NO_SOCKET = -1;
static void closeSocket( Socket s ) { close( s ); }
#endif

namespace trigit
{
/// How often the engine hears that time has passed, for Stop and lost-source
/// detection. Firing does not wait for it: a packet wakes the thread at once.
static const int TICK_MILLISECONDS = 10;

static const char bootstrap[] = R"(
local chunks, loaded = ..., {}
function require(name)
    if loaded[name] == nil then loaded[name] = assert(chunks[name], name)() end
    return loaded[name]
end
host = require("host")
)";

struct Core::Impl
{
	mutable std::mutex mutex;//Guards everything the host's threads share with ours.
	Status status;
	std::string pendingText, pendingPath;
	bool hasPendingText = false, hasPendingPath = false, hasPendingArmed = false, pendingArmed = false;
	std::atomic< uint16_t > boundPort{ 0 };
	std::atomic< bool > running{ true };

	//Our thread's own.
	lua_State* lua = nullptr;
	Socket input = NO_SOCKET, output = NO_SOCKET;
	std::thread thread;
	std::string notice;//A problem of ours to show instead of the engine's last message.

	static double now()
	{
		return std::chrono::duration< double >( std::chrono::steady_clock::now().time_since_epoch() ).count();
	}

	void say( const std::string& message )
	{
		std::lock_guard< std::mutex > lock( mutex );
		status.message = message;
	}

	/// host.send(address, port, bytes): one UDP datagram; true if it went out.
	static int send( lua_State* L )
	{
		Impl* self = static_cast< Impl* >( lua_touserdata( L, lua_upvalueindex( 1 ) ) );
		size_t size    = 0;
		const char* address = luaL_checkstring( L, 1 );
		lua_Integer port    = luaL_checkinteger( L, 2 );
		const char* bytes   = luaL_checklstring( L, 3, &size );
		sockaddr_in to{};
		to.sin_family = AF_INET;
		to.sin_port   = htons( static_cast< uint16_t >( port ) );
		bool sent     = self->output != NO_SOCKET && port > 0 && port < 65536 &&
		                inet_pton( AF_INET, address, &to.sin_addr ) == 1 &&
		                sendto( self->output, bytes, static_cast< int >( size ), 0, reinterpret_cast< sockaddr* >( &to ), sizeof to ) == static_cast< int >( size );
		lua_pushboolean( L, sent );
		return 1;
	}

	bool startLua()
	{
		lua = luaL_newstate();
		if( !lua )
			return false;
		//No io, os or package: the Set is data and the scripts are built in.
		luaL_requiref( lua, LUA_GNAME, luaopen_base, 1 );
		luaL_requiref( lua, LUA_STRLIBNAME, luaopen_string, 1 );
		luaL_requiref( lua, LUA_TABLIBNAME, luaopen_table, 1 );
		luaL_requiref( lua, LUA_MATHLIBNAME, luaopen_math, 1 );
		lua_settop( lua, 0 );

		if( luaL_loadbuffer( lua, bootstrap, sizeof bootstrap - 1, "=bootstrap" ) != LUA_OK )
			return false;
		lua_newtable( lua );
		for( const EmbeddedLua& module : embeddedLua )
		{
			std::string chunkName = std::string( "=" ) + module.name;
			if( luaL_loadbuffer( lua, reinterpret_cast< const char* >( module.data ), module.size, chunkName.c_str() ) != LUA_OK )
				return false;
			lua_setfield( lua, -2, module.name );
		}
		if( lua_pcall( lua, 1, 0, 0 ) != LUA_OK )
			return false;
		lua_getglobal( lua, "host" );
		lua_pushlightuserdata( lua, this );
		lua_pushcclosure( lua, &Impl::send, 1 );
		lua_setfield( lua, -2, "send" );
		lua_pop( lua, 1 );
		return true;
	}

	/// Calls host.<name> with the arguments pushed by `push` (which returns how many).
	template< typename Push >
	bool call( const char* name, int results, Push push )
	{
		lua_getglobal( lua, "host" );
		lua_getfield( lua, -1, name );
		lua_remove( lua, -2 );
		int arguments = push();
		if( lua_pcall( lua, arguments, results, 0 ) == LUA_OK )
			return true;
		const char* error = lua_tostring( lua, -1 );
		notice = std::string( "TrigIT error: " ) + ( error ? error : "?" );
		lua_pop( lua, 1 );
		return false;
	}

	void openSockets( uint16_t port )
	{
#ifdef _WIN32
		WSADATA data;
		WSAStartup( MAKEWORD( 2, 2 ), &data );
#endif
		int yes = 1;
		output  = socket( AF_INET, SOCK_DGRAM, 0 );
		if( output != NO_SOCKET )
			setsockopt( output, SOL_SOCKET, SO_BROADCAST, reinterpret_cast< const char* >( &yes ), sizeof yes );

		//Share the Art-Net port: the host or other software may listen on it too.
		input = socket( AF_INET, SOCK_DGRAM, 0 );
		if( input == NO_SOCKET )
			return;
		setsockopt( input, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast< const char* >( &yes ), sizeof yes );
#ifdef SO_REUSEPORT
		setsockopt( input, SOL_SOCKET, SO_REUSEPORT, reinterpret_cast< const char* >( &yes ), sizeof yes );
#endif
		sockaddr_in address{};
		address.sin_family      = AF_INET;
		address.sin_addr.s_addr = htonl( INADDR_ANY );
		address.sin_port        = htons( port );
		socklen_t length        = sizeof address;
		if( bind( input, reinterpret_cast< sockaddr* >( &address ), sizeof address ) != 0 ||
		    getsockname( input, reinterpret_cast< sockaddr* >( &address ), &length ) != 0 )
		{
			closeSocket( input );
			input = NO_SOCKET;
			return;
		}
		boundPort = ntohs( address.sin_port );
	}

	void applyPending()
	{
		std::string text, path;
		bool loadText, loadPath, arm, armed;
		{
			std::lock_guard< std::mutex > lock( mutex );
			loadText = hasPendingText, loadPath = hasPendingPath, arm = hasPendingArmed, armed = pendingArmed;
			text.swap( pendingText );
			path.swap( pendingPath );
			hasPendingText = hasPendingPath = hasPendingArmed = false;
		}
		if( loadText || loadPath )
			notice.clear();
		if( loadPath )
		{
			std::ifstream file( path, std::ios::binary );
			std::stringstream contents;
			contents << file.rdbuf();
			if( file )
				text = contents.str(), loadText = true;
			else
				notice = "Could not read " + path;
		}
		if( loadText && call( "load", 1, [ & ] { lua_pushlstring( lua, text.data(), text.size() ); return 1; } ) )
			lua_pop( lua, 1 );
		if( arm )
			call( "setArmed", 0, [ & ] { lua_pushboolean( lua, armed ); return 1; } );
	}

	void publishStatus()
	{
		if( !call( "status", 5, [] { return 0; } ) )
			return;
		Status next;
		next.playhead = lua_tostring( lua, -5 );
		next.song     = lua_tostring( lua, -4 );
		next.armed    = lua_toboolean( lua, -3 ) != 0;
		next.alert    = lua_tostring( lua, -2 );
		next.message  = notice.empty() ? lua_tostring( lua, -1 ) : notice;
		lua_pop( lua, 5 );
		std::lock_guard< std::mutex > lock( mutex );
		status = std::move( next );
	}

	void run( uint16_t port )
	{
		openSockets( port );
		if( !startLua() )
		{
			const char* error = lua ? lua_tostring( lua, -1 ) : nullptr;
			say( std::string( "TrigIT could not start: " ) + ( error ? error : "out of memory" ) );
			return;
		}
		bool listening = input != NO_SOCKET;
		char buffer[ 1500 ];
		while( running )
		{
			applyPending();
			bool received = false;
			if( listening )
			{
				fd_set set;
				FD_ZERO( &set );
				FD_SET( input, &set );
				timeval timeout{ 0, TICK_MILLISECONDS * 1000 };
				if( select( static_cast< int >( input ) + 1, &set, nullptr, nullptr, &timeout ) > 0 )
				{
					int size = static_cast< int >( recv( input, buffer, sizeof buffer, 0 ) );
					double at = now();
					received  = size > 0;
					if( received )
						call( "packet", 0, [ & ] { lua_pushlstring( lua, buffer, size ); lua_pushnumber( lua, at ); return 2; } );
				}
			}
			else
				std::this_thread::sleep_for( std::chrono::milliseconds( TICK_MILLISECONDS ) );
			if( !received )
				call( "tick", 0, [ & ] { lua_pushnumber( lua, now() ); return 1; } );
			if( !listening && notice.empty() )
				notice = "Art-Net port " + std::to_string( port ) + " could not be opened";
			publishStatus();
		}
	}
};

std::shared_ptr< Core > Core::shared()
{
	static std::mutex mutex;
	static std::weak_ptr< Core > existing;
	std::lock_guard< std::mutex > lock( mutex );
	std::shared_ptr< Core > core = existing.lock();
	if( !core )
		existing = core = std::make_shared< Core >();
	return core;
}

Core::Core( uint16_t port ) :
	impl( new Impl )
{
	impl->thread = std::thread( [ this, port ] { impl->run( port ); } );
}

Core::~Core()
{
	impl->running = false;
	impl->thread.join();
	if( impl->lua )
		lua_close( impl->lua );
	if( impl->input != NO_SOCKET )
		closeSocket( impl->input );
	if( impl->output != NO_SOCKET )
		closeSocket( impl->output );
}

void Core::loadSetFile( const std::string& path )
{
	std::lock_guard< std::mutex > lock( impl->mutex );
	impl->pendingPath = path, impl->hasPendingPath = true;
}

void Core::loadSetText( const std::string& json )
{
	std::lock_guard< std::mutex > lock( impl->mutex );
	impl->pendingText = json, impl->hasPendingText = true;
}

void Core::setArmed( bool armed )
{
	std::lock_guard< std::mutex > lock( impl->mutex );
	impl->pendingArmed = armed, impl->hasPendingArmed = true;
}

Status Core::status() const
{
	std::lock_guard< std::mutex > lock( impl->mutex );
	return impl->status;
}

uint16_t Core::port() const
{
	return impl->boundPort;
}
}

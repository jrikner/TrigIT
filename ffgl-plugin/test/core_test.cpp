// SPDX-License-Identifier: GPL-3.0-or-later
// Drives the Core as a show would: Art-Net Timecode in over loopback UDP, the
// Set's OSC out to a socket we listen on. The OSC bytes expected are the OSC
// 1.0 specification's examples, as Tests/TrigITProtocolsTests/OSCTests.swift.
#include "TrigITCore.h"

#include <chrono>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET Socket;
typedef int socklen_t;
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
typedef int Socket;
#endif

static int failures = 0;

static void check( bool ok, const std::string& what )
{
	std::printf( "%s %s\n", ok ? "ok  " : "FAIL", what.c_str() );
	if( !ok )
		++failures;
}

static sockaddr_in loopback( uint16_t port )
{
	sockaddr_in address{};
	address.sin_family      = AF_INET;
	address.sin_addr.s_addr = htonl( INADDR_LOOPBACK );
	address.sin_port        = htons( port );
	return address;
}

static void sendTimecode( Socket s, uint16_t port, int h, int m, int sec, int f, int type )
{
	std::string packet( "Art-Net\0\0\x97\0\x0e\0\0", 14 );
	packet += { char( f ), char( sec ), char( m ), char( h ), char( type ) };
	sockaddr_in to = loopback( port );
	sendto( s, packet.data(), int( packet.size() ), 0, reinterpret_cast< sockaddr* >( &to ), sizeof to );
}

/// The next datagram within `milliseconds`, empty if none came.
static std::string receive( Socket s, int milliseconds )
{
	fd_set set;
	FD_ZERO( &set );
	FD_SET( s, &set );
	timeval timeout{ milliseconds / 1000, ( milliseconds % 1000 ) * 1000 };
	char buffer[ 1500 ];
	if( select( int( s ) + 1, &set, nullptr, nullptr, &timeout ) <= 0 )
		return "";
	int size = int( recv( s, buffer, sizeof buffer, 0 ) );
	return size > 0 ? std::string( buffer, size ) : "";
}

template< typename Condition >
static bool eventually( Condition condition )
{
	for( int i = 0; i < 200 && !condition(); ++i )
		std::this_thread::sleep_for( std::chrono::milliseconds( 10 ) );
	return condition();
}

int main()
{
	trigit::Core core( 0 );
	check( eventually( [ & ] { return core.port() != 0; } ), "follows a UDP port" );

	Socket receiver   = socket( AF_INET, SOCK_DGRAM, 0 );
	sockaddr_in bound = loopback( 0 );
	socklen_t length  = sizeof bound;
	bind( receiver, reinterpret_cast< sockaddr* >( &bound ), sizeof bound );
	getsockname( receiver, reinterpret_cast< sockaddr* >( &bound ), &length );
	Socket sender = socket( AF_INET, SOCK_DGRAM, 0 );

	core.loadSetText( "this is not a Set" );
	check( eventually( [ & ] { return core.status().message == "Not a TrigIT Set file"; } ), "refuses a file that is not a Set" );

	std::string port = std::to_string( ntohs( bound.sin_port ) );
	core.loadSetText( R"({"format":"TrigIT Set","version":1,"set":{"id":"1","name":"Test","stopTime":2,
		"destinations":[{"id":"100","name":"Resolume","host":"127.0.0.1","port":)" + port + R"(,"usesOSC":true,"usesMIDI":true,"usesDMX":false}],
		"songs":[
		 {"id":"10","name":"Intro","start":"01:00:00:00","end":"01:04:00:00","stopActions":[],"startActions":[
		   {"id":"1","destination":"100","type":"osc","osc":{"address":"/foo","arguments":[{"int":1000},{"int":-1},{"string":"hello"},{"float":1.234},{"float":5.678}]}}]},
		 {"id":"11","name":"Drop","start":"02:00:00:00","end":"02:01:00:00","stopActions":[],"startActions":[
		   {"id":"2","destination":"100","type":"midiNote","midiNote":{"channel":0,"note":60,"velocity":127}},
		   {"id":"3","destination":"100","type":"osc","osc":{"address":"/oscillator/4/frequency","arguments":[{"float":440.0}]}}]}]}})" );
	check( eventually( [ & ] { return core.status().message == "Loaded Test: 2 Songs, 1 Actions are not OSC and will not be sent"; } ),
	       "loads a Set and counts the Actions it can't send" );

	sendTimecode( sender, core.port(), 1, 0, 0, 0, 1 );
	check( receive( receiver, 300 ).empty(), "sends nothing while disarmed" );
	check( core.status().playhead == "01:00:00:00" && core.status().song == "Intro", "shows the Playhead and current Song" );

	core.setArmed( true );
	check( eventually( [ & ] { return core.status().armed; } ), "arms" );
	check( receive( receiver, 100 ).empty(), "arming inside a Song fires nothing" );

	sendTimecode( sender, core.port(), 2, 0, 0, 0, 1 );
	std::string frequency( "/oscillator/4/frequency\0,f\0\0\x43\xdc\0\0", 32 );
	check( receive( receiver, 1000 ) == frequency, "entering a Song sends its OSC Action, byte for byte" );
	check( receive( receiver, 100 ).empty(), "and nothing for the MIDI Action" );

	sendTimecode( sender, core.port(), 1, 0, 0, 5, 1 );
	std::string foo( "/foo\0\0\0\0,iisff\0\0\0\0\x03\xe8\xff\xff\xff\xffhello\0\0\0\x3f\x9d\xf3\xb6\x40\xb5\xb2\x2d", 40 );
	check( receive( receiver, 1000 ) == foo, "int, string and float arguments match the OSC specification's example" );

	sendTimecode( sender, core.port(), 1, 0, 0, 6, 1 );
	check( receive( receiver, 100 ).empty(), "playing on inside a Song fires nothing more" );
	sendTimecode( sender, core.port(), 1, 0, 0, 30, 1 );
	sendTimecode( sender, core.port(), 2, 0, 0, 0, 9 );
	check( receive( receiver, 100 ).empty() && core.status().playhead == "01:00:00:06", "ignores timecode that is not valid" );

	check( eventually( [ & ] { return core.status().message == "Timecode stopped"; } ), "a Stop after the Set's Stop time of silence" );

	//Cues typed into the plugin's parameters, with no Set file.
	core.setCues( { { "03:00:00:00", "2" }, { "", "" }, { "03:00:10;00", "/foo 1000 -1 hello 1.234 5.678" }, { "3 o'clock", "1" } }, port );
	check( eventually( [ & ] { return core.status().message == "Cue 4: the time must be hh:mm:ss:ff"; } ), "names the Cue it can't read" );
	sendTimecode( sender, core.port(), 3, 0, 0, 0, 1 );
	std::string column( "/composition/columns/2/connect\0\0,i\0\0\0\0\0\x01", 40 );
	check( receive( receiver, 1000 ) == column, "a Cue with a column number launches that Resolume column" );
	sendTimecode( sender, core.port(), 3, 0, 9, 24, 1 );
	check( receive( receiver, 100 ).empty(), "nothing fires before the next Cue's time" );
	sendTimecode( sender, core.port(), 3, 0, 10, 0, 1 );
	check( receive( receiver, 1000 ) == foo, "the next Cue fires on its own frame, with its OSC address and arguments" );
	core.setCues( { { "", "" } }, port );
	check( eventually( [ & ] { return core.status().message.rfind( "Loaded Test:", 0 ) == 0; } ), "with no Cues, the Set file is the Set again" );

	std::printf( failures ? "%d FAILED\n" : "all passed\n", failures );
	return failures ? 1 : 0;
}

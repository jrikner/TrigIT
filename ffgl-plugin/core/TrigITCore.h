// SPDX-License-Identifier: GPL-3.0-or-later
// TrigIT's Show Engine with its own thread and sockets, for hosting inside
// another program (the FFGL plugin). It follows Art-Net Timecode on a UDP port
// and sends the Set's OSC Actions. No OpenGL, no FFGL: testable on its own.
#pragma once
#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace trigit
{
struct Status
{
	std::string playhead;//!< "hh:mm:ss:ff", empty before any timecode.
	std::string song;    //!< The current Song's name, empty if none.
	std::string alert;   //!< A timecode alert, empty if none.
	std::string message; //!< The last thing that happened, for a log line.
	bool armed = false;
};

class Core
{
public:
	static const uint16_t ART_NET_PORT = 6454;

	/// The one Core every plugin instance in a process shares, so two copies of
	/// the effect never fire a Song twice. It lives while anyone holds it.
	static std::shared_ptr< Core > shared();

	/// Starts following timecode on `port` (0: any free port, for tests).
	explicit Core( uint16_t port = ART_NET_PORT );
	~Core();
	Core( const Core& ) = delete;
	Core& operator=( const Core& ) = delete;

	/// These return at once; the engine's thread applies them within a tick.
	void loadSetFile( const std::string& path );
	void loadSetText( const std::string& json );
	void setArmed( bool armed );
	/// Cues typed into the host instead of a Set file: a time ("hh:mm:ss:ff") and
	/// a target (a Resolume column number, or an OSC address and arguments)
	/// each, sent to `oscPort` on this computer. If any is filled in, the Cues
	/// are the Set; otherwise the file is.
	void setCues( const std::vector< std::pair< std::string, std::string > >& cues, const std::string& oscPort );

	Status status() const;
	/// The UDP port timecode is followed on, 0 if it could not be opened.
	uint16_t port() const;

private:
	struct Impl;
	std::unique_ptr< Impl > impl;
};
}

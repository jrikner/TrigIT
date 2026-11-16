// SPDX-License-Identifier: GPL-3.0-or-later
// TrigIT as an FFGL effect. The video passes through untouched; the effect is
// only a home for the Show Engine (core/TrigITCore), which follows Art-Net
// Timecode and sends the Set's OSC Actions from its own thread. "Show timecode"
// draws the Playhead over the picture, to check that timecode is arriving.
#include "TrigITCore.h"
#include <FFGLSDK.h>
#include <memory>
#include <string>
#include <utility>
#include <vector>

using namespace ffglex;

enum Param : FFUInt32
{
	PARAM_SET,
	PARAM_ARMED,
	PARAM_SHOW,
	PARAM_OSC_PORT,
	PARAM_FIRST_CUE,//Then a time and a target for each Cue.
};
static const unsigned int CUE_COUNT = 16;

static const char vertexShader[] = R"(#version 410 core
uniform vec2 MaxUV;
layout( location = 0 ) in vec4 vPosition;
layout( location = 1 ) in vec2 vUV;
out vec2 uv;
out vec2 textureUV;
void main()
{
	gl_Position = vPosition;
	uv = vUV;
	textureUV = vUV * MaxUV;
}
)";

// Eight seven-segment digits, hh:mm:ss:ff, across the middle of the picture.
// A digit of -1 draws a dash.
static const char fragmentShader[] = R"(#version 410 core
uniform sampler2D inputTexture;
uniform int digits[ 8 ];
uniform vec3 tint;
uniform float show;
uniform float aspect;
in vec2 uv;
in vec2 textureUV;
out vec4 fragColor;

const int MASKS[ 10 ] = int[ 10 ]( 0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F );

float line( vec2 p, vec2 a, vec2 b )
{
	vec2 pa = p - a, ba = b - a;
	return length( pa - ba * clamp( dot( pa, ba ) / dot( ba, ba ), 0.0, 1.0 ) );
}

//p is in a cell 1 wide and 2 high.
float digit( vec2 p, int value )
{
	int mask = value < 0 ? 0x40 : MASKS[ value ];
	vec2 A = vec2( 0.2, 1.8 ), B = vec2( 0.8, 1.8 ), C = vec2( 0.8, 1.0 ), D = vec2( 0.8, 0.2 ), E = vec2( 0.2, 0.2 ), F = vec2( 0.2, 1.0 );
	float d = 1e9;
	if( ( mask & 1 ) != 0 ) d = min( d, line( p, A, B ) );
	if( ( mask & 2 ) != 0 ) d = min( d, line( p, B, C ) );
	if( ( mask & 4 ) != 0 ) d = min( d, line( p, C, D ) );
	if( ( mask & 8 ) != 0 ) d = min( d, line( p, D, E ) );
	if( ( mask & 16 ) != 0 ) d = min( d, line( p, E, F ) );
	if( ( mask & 32 ) != 0 ) d = min( d, line( p, F, A ) );
	if( ( mask & 64 ) != 0 ) d = min( d, line( p, F, C ) );
	return 1.0 - smoothstep( 0.06, 0.09, d );
}

void main()
{
	fragColor = texture( inputTexture, textureUV );
	if( show < 0.5 )
		return;
	//13 cells: a margin, then 8 digits with 3 colons between the pairs.
	float x = uv.x * 13.0 - 1.0;
	vec2 p = vec2( fract( x ), ( uv.y - 0.5 ) * 13.0 / aspect + 1.0 );
	int cell = int( floor( x ) );
	if( x < 0.0 || cell > 10 || p.y < 0.0 || p.y > 2.0 )
		return;
	float lit;
	if( cell % 3 == 2 )
		lit = 1.0 - smoothstep( 0.08, 0.11, min( distance( p, vec2( 0.5, 0.6 ) ), distance( p, vec2( 0.5, 1.4 ) ) ) );
	else
		lit = digit( p, digits[ cell - cell / 3 ] );
	fragColor = mix( fragColor, vec4( tint, 1.0 ), lit );
}
)";

class TrigITFFGL : public CFFGLPlugin
{
public:
	TrigITFFGL()
	{
		SetMinInputs( 1 );
		SetMaxInputs( 1 );
		SetFileParamInfo( PARAM_SET, "Set", { "trigit" }, "" );
		SetParamInfo( PARAM_ARMED, "Armed", FF_TYPE_BOOLEAN, false );
		SetParamInfo( PARAM_SHOW, "Show timecode", FF_TYPE_BOOLEAN, false );
		SetParamInfo( PARAM_OSC_PORT, "Cue OSC port", FF_TYPE_TEXT, "7000" );
		for( unsigned int i = 0; i < CUE_COUNT; ++i )
		{
			SetParamInfo( PARAM_FIRST_CUE + i * 2, ( "Cue " + std::to_string( i + 1 ) + " time" ).c_str(), FF_TYPE_TEXT, "" );
			SetParamInfo( PARAM_FIRST_CUE + i * 2 + 1, ( "Cue " + std::to_string( i + 1 ) + " column" ).c_str(), FF_TYPE_TEXT, "" );
		}
	}

	FFResult InitGL( const FFGLViewportStruct* vp ) override
	{
		if( !shader.Compile( vertexShader, fragmentShader ) || !quad.Initialise() )
		{
			DeInitGL();
			return FF_FAIL;
		}
		//The engine runs from here until DeInitGL, whether or not frames are drawn.
		core = trigit::Core::shared();
		if( !setPath.empty() )
			core->loadSetFile( setPath );
		core->setCues( cues, oscPort );
		core->setArmed( armed );
		return CFFGLPlugin::InitGL( vp );
	}

	FFResult DeInitGL() override
	{
		core.reset();
		shader.FreeGLResources();
		quad.Release();
		return FF_SUCCESS;
	}

	FFResult ProcessOpenGL( ProcessOpenGLStruct* pGL ) override
	{
		if( pGL->numInputTextures < 1 || pGL->inputTextures[ 0 ] == nullptr )
			return FF_FAIL;

		ScopedShaderBinding shaderBinding( shader.GetGLID() );
		ScopedSamplerActivation activateSampler( 0 );
		Scoped2DTextureBinding textureBinding( pGL->inputTextures[ 0 ]->Handle );
		shader.Set( "inputTexture", 0 );
		FFGLTexCoords maxCoords = GetMaxGLTexCoords( *pGL->inputTextures[ 0 ] );
		shader.Set( "MaxUV", maxCoords.s, maxCoords.t );
		shader.Set( "show", showTimecode ? 1.0f : 0.0f );

		trigit::Status status = core ? core->status() : trigit::Status();
		if( status.message != lastMessage )
		{
			//Resolume's log is the plugin's Fire Log.
			lastMessage = status.message;
			FFGLLog::LogToHost( ( "TrigIT: " + lastMessage ).c_str() );
		}
		if( showTimecode )
		{
			//"hh:mm:ss:ff" has its digits at 0,1 3,4 6,7 9,10.
			GLint digits[ 8 ];
			for( int i = 0; i < 8; ++i )
				digits[ i ] = status.playhead.size() == 11 ? status.playhead[ i + i / 2 ] - '0' : -1;
			glUniform1iv( shader.FindUniform( "digits" ), 8, digits );
			//Red: a timecode alert. Green: armed. Grey: disarmed, nothing will fire.
			if( !status.alert.empty() )
				shader.Set( "tint", 1.0f, 0.2f, 0.2f );
			else if( status.armed )
				shader.Set( "tint", 0.2f, 1.0f, 0.4f );
			else
				shader.Set( "tint", 0.7f, 0.7f, 0.7f );
			shader.Set( "aspect", currentViewport.height > 0 ? float( currentViewport.width ) / float( currentViewport.height ) : 1.0f );
		}

		quad.Draw();
		return FF_SUCCESS;
	}

	FFResult SetFloatParameter( unsigned int index, float value ) override
	{
		if( index == PARAM_ARMED )
		{
			armed = value > 0.5f;
			if( core )
				core->setArmed( armed );
		}
		else if( index == PARAM_SHOW )
			showTimecode = value > 0.5f;
		else
			return FF_FAIL;
		return FF_SUCCESS;
	}

	float GetFloatParameter( unsigned int index ) override
	{
		return ( index == PARAM_ARMED ? armed : index == PARAM_SHOW ? showTimecode : false ) ? 1.0f : 0.0f;
	}

	FFResult SetTextParameter( unsigned int index, const char* value ) override
	{
		std::string text = value ? value : "";
		if( index == PARAM_SET )
		{
			setPath = text;
			if( core && !setPath.empty() )
				core->loadSetFile( setPath );
			return FF_SUCCESS;
		}
		std::string* cue = cueText( index );
		if( !cue )
			return FF_FAIL;
		*cue = text;
		if( core )
			core->setCues( cues, oscPort );
		return FF_SUCCESS;
	}

	char* GetTextParameter( unsigned int index ) override
	{
		std::string* text = index == PARAM_SET ? &setPath : cueText( index );
		return text ? const_cast< char* >( text->c_str() ) : nullptr;
	}

private:
	/// The text behind the OSC port or a Cue parameter, nullptr for any other.
	std::string* cueText( unsigned int index )
	{
		if( index == PARAM_OSC_PORT )
			return &oscPort;
		if( index < PARAM_FIRST_CUE || index >= PARAM_FIRST_CUE + CUE_COUNT * 2 )
			return nullptr;
		auto& cue = cues[ ( index - PARAM_FIRST_CUE ) / 2 ];
		return ( index - PARAM_FIRST_CUE ) % 2 == 0 ? &cue.first : &cue.second;
	}

	std::vector< std::pair< std::string, std::string > > cues = std::vector< std::pair< std::string, std::string > >( CUE_COUNT );
	std::string oscPort = "7000";
	std::shared_ptr< trigit::Core > core;
	std::string setPath, lastMessage;
	bool armed = false, showTimecode = false;
	FFGLShader shader;
	FFGLScreenQuad quad;
};

static CFFGLPluginInfo PluginInfo(
	PluginFactory< TrigITFFGL >,// Create method
	"TRIG",                     // Plugin unique ID
	"TrigIT",                   // Plugin name
	2,                          // API major version number
	1,                          // API minor version number
	0,                          // Plugin major version number
	1,                          // Plugin minor version number
	FF_EFFECT,                  // Plugin type
	"Fires a TrigIT Set's OSC cues from Art-Net Timecode",// Plugin description
	"TrigIT, GPL-3.0-or-later. https://github.com/jrikner/TrigIT"// About
);

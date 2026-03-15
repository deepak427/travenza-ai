import google.genai as genai
from google.genai import types
import asyncio
import inspect
import logging
import json
import os
from typing import Optional, Callable, Dict, Any

logger = logging.getLogger(__name__)


class GeminiLive:
    def __init__(self, project_id: str, location: str, model: str, input_sample_rate: int = 16000):
        self.project_id = project_id
        self.location = location
        self.model = model
        self.input_sample_rate = input_sample_rate
        
        api_key = os.getenv("GOOGLE_API_KEY")
        if api_key:
            logger.info("Using Gemini API Key for authentication")
            self.client = genai.Client(api_key=api_key)
        else:
            logger.info("Using Vertex AI (ADC) for authentication")
            self.client = genai.Client(vertexai=True, project=project_id, location=location)
            
        self.tool_mapping: Dict[str, Callable] = {}
        logger.info(f"GeminiLive initialized | model={model}")

    def register_tool(self, func: Callable):
        self.tool_mapping[func.__name__] = func
        return func

    async def start_session(
        self,
        audio_input_queue: asyncio.Queue,
        text_input_queue: asyncio.Queue,
        audio_output_callback: Callable,
        audio_interrupt_callback: Optional[Callable] = None,
        setup_config: Optional[Dict[str, Any]] = None
    ):
        config_args = {
            "response_modalities": [types.Modality.AUDIO],
        }

        # If client provided setup_config, use it to override/populate
        if setup_config:
            if "generation_config" in setup_config:
                gen_config = setup_config["generation_config"]
                if "speech_config" in gen_config:
                    try:
                        voice_name = gen_config["speech_config"]["voice_config"]["prebuilt_voice_config"]["voice_name"]
                        config_args["speech_config"] = types.SpeechConfig(
                            voice_config=types.VoiceConfig(
                                prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name=voice_name)
                            )
                        )
                    except (KeyError, TypeError):
                        pass
                
                if "temperature" in gen_config:
                    config_args["temperature"] = gen_config["temperature"]

            if "system_instruction" in setup_config:
                try:
                    text = setup_config["system_instruction"]["parts"][0]["text"]
                    config_args["system_instruction"] = types.Content(parts=[types.Part(text=text)])
                except (KeyError, IndexError, TypeError):
                    pass

            if "proactivity" in setup_config:
                try:
                    p = setup_config["proactivity"]
                    config_args["proactivity"] = types.ProactivityConfig(
                        proactive_audio=p.get("proactiveAudio", False)
                    )
                except Exception:
                    pass

            if "input_audio_transcription" in setup_config:
                config_args["input_audio_transcription"] = types.AudioTranscriptionConfig()
            if "output_audio_transcription" in setup_config:
                config_args["output_audio_transcription"] = types.AudioTranscriptionConfig()

        config = types.LiveConnectConfig(**config_args)

        async with self.client.aio.live.connect(model=self.model, config=config) as session:

            async def send_audio():
                try:
                    while True:
                        chunk = await audio_input_queue.get()
                        await session.send_realtime_input(
                            audio=types.Blob(
                                data=chunk,
                                mime_type=f"audio/pcm;rate={self.input_sample_rate}"
                            )
                        )
                except asyncio.CancelledError:
                    pass

            async def send_text():
                try:
                    while True:
                        text = await text_input_queue.get()
                        await session.send(input=text, end_of_turn=True)
                except asyncio.CancelledError:
                    pass

            event_queue: asyncio.Queue = asyncio.Queue()

            async def receive_loop():
                try:
                    while True:
                        async for response in session.receive():
                            sc = response.server_content
                            tc = response.tool_call

                            if sc:
                                if sc.model_turn:
                                    for part in sc.model_turn.parts:
                                        if part.inline_data:
                                            if inspect.iscoroutinefunction(audio_output_callback):
                                                await audio_output_callback(part.inline_data.data)
                                            else:
                                                audio_output_callback(part.inline_data.data)

                                if sc.input_transcription:
                                    await event_queue.put({
                                        "serverContent": {
                                            "inputTranscription": {
                                                "text": sc.input_transcription.text,
                                                "finished": True,
                                            }
                                        }
                                    })

                                if sc.output_transcription:
                                    await event_queue.put({
                                        "serverContent": {
                                            "outputTranscription": {
                                                "text": sc.output_transcription.text,
                                                "finished": True,
                                            }
                                        }
                                    })

                                if sc.turn_complete:
                                    await event_queue.put({"serverContent": {"turnComplete": True}})

                                if sc.interrupted:
                                    await event_queue.put({"serverContent": {"interrupted": True}})
                                    if audio_interrupt_callback:
                                        if inspect.iscoroutinefunction(audio_interrupt_callback):
                                            await audio_interrupt_callback()
                                        else:
                                            audio_interrupt_callback()

                            if tc:
                                function_responses = []
                                client_tool_calls = []

                                for fc in tc.function_calls:
                                    args = fc.args or {}
                                    if fc.name in self.tool_mapping:
                                        try:
                                            fn = self.tool_mapping[fc.name]
                                            if inspect.iscoroutinefunction(fn):
                                                result = await fn(**args)
                                            else:
                                                loop = asyncio.get_running_loop()
                                                result = await loop.run_in_executor(None, lambda: fn(**args))
                                        except Exception as e:
                                            result = f"Error: {e}"
                                        function_responses.append(types.FunctionResponse(
                                            name=fc.name, id=fc.id, response={"result": result}
                                        ))
                                        await event_queue.put({
                                            "type": "tool_call",
                                            "name": fc.name,
                                            "args": args,
                                            "result": result,
                                        })
                                    else:
                                        client_tool_calls.append({
                                            "name": fc.name,
                                            "args": args,
                                            "id": fc.id,
                                        })

                                if client_tool_calls:
                                    await event_queue.put({"toolCall": {"functionCalls": client_tool_calls}})
                                if function_responses:
                                    await session.send_tool_response(function_responses=function_responses)

                except asyncio.CancelledError:
                    pass
                except Exception as e:
                    logger.error(f"receive_loop error: {e}")
                    await event_queue.put({"type": "error", "error": str(e)})
                finally:
                    await event_queue.put(None)

            send_audio_task = asyncio.create_task(send_audio())
            send_text_task = asyncio.create_task(send_text())
            receive_task = asyncio.create_task(receive_loop())

            try:
                while True:
                    event = await event_queue.get()
                    if event is None:
                        break
                    yield event
                logger.info("Session event loop finished")
            finally:
                send_audio_task.cancel()
                send_text_task.cancel()
                receive_task.cancel()

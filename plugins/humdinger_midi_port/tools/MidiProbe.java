// A MIDI client that runs outside the app, as the adb shell user, to prove
// that another process can open the Humdinger port and receive what the app
// sends. It finds the first device whose name matches the argument, opens its
// output port 0 and prints every message it receives, one line each:
//
//   RECV 90 45 5c
//
// Build and run with tools/midi_probe.sh. It runs under app_process, so it
// has no Context: it reaches the platform MidiManager through its (hidden)
// IMidiManager constructor, which app_process code may call.
//
// A third argument, stall seconds, makes it a stuck client: it stops reading
// on the first message for that long (prints STALL / RESUME), so the app's
// writer fills up behind it.
import android.media.midi.MidiDevice;
import android.media.midi.MidiDeviceInfo;
import android.media.midi.MidiManager;
import android.media.midi.MidiOutputPort;
import android.media.midi.MidiReceiver;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import java.lang.reflect.Constructor;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

public final class MidiProbe {
    public static void main(String[] args) throws Exception {
        String wanted = args.length > 0 ? args[0] : "Humdinger";
        long seconds = args.length > 1 ? Long.parseLong(args[1]) : 30;
        final long stallMs = args.length > 2 ? Long.parseLong(args[2]) * 1000 : 0;
        final boolean[] stalled = {false};

        MidiManager mm = midiManager();
        MidiDeviceInfo info = null;
        for (MidiDeviceInfo d : mm.getDevices()) {
            String name = d.getProperties().getString(MidiDeviceInfo.PROPERTY_NAME);
            say("DEVICE id=" + d.getId() + " name=" + name + " type=" + d.getType()
                    + " in=" + d.getInputPortCount() + " out=" + d.getOutputPortCount());
            if (info == null && wanted.equals(name)) info = d;
        }
        if (info == null) {
            say("NOT_FOUND " + wanted);
            System.exit(2);
        }
        if (info.getOutputPortCount() < 1) {
            say("NO_OUTPUT_PORT " + wanted);
            System.exit(3);
        }

        HandlerThread thread = new HandlerThread("midi-probe");
        thread.start();
        Handler handler = new Handler(thread.getLooper());
        CountDownLatch opened = new CountDownLatch(1);
        MidiDevice[] device = new MidiDevice[1];
        mm.openDevice(info, d -> {
            device[0] = d;
            opened.countDown();
        }, handler);
        if (!opened.await(10, TimeUnit.SECONDS) || device[0] == null) {
            say("OPEN_FAILED " + wanted);
            System.exit(4);
        }

        MidiOutputPort port = device[0].openOutputPort(0);
        if (port == null) {
            say("PORT_BUSY " + wanted);
            System.exit(5);
        }
        port.connect(new MidiReceiver() {
            @Override
            public void onSend(byte[] msg, int offset, int count, long timestamp) {
                if (stallMs > 0 && !stalled[0]) {
                    stalled[0] = true;
                    say("STALL " + stallMs + "ms");
                    try {
                        Thread.sleep(stallMs);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    }
                    say("RESUME");
                }
                StringBuilder line = new StringBuilder("RECV");
                for (int i = offset; i < offset + count; i++) {
                    line.append(String.format(" %02x", msg[i] & 0xff));
                }
                say(line.toString());
            }
        });
        say("LISTENING id=" + info.getId() + " for " + seconds + "s");
        Thread.sleep(seconds * 1000);
        port.close();
        device[0].close();
        say("DONE");
        System.exit(0);
    }

    private static MidiManager midiManager() throws Exception {
        IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class)
                .invoke(null, "midi");
        Class<?> iface = Class.forName("android.media.midi.IMidiManager");
        Object service = Class.forName("android.media.midi.IMidiManager$Stub")
                .getMethod("asInterface", IBinder.class)
                .invoke(null, binder);
        Constructor<MidiManager> ctor = MidiManager.class.getDeclaredConstructor(iface);
        ctor.setAccessible(true);
        return ctor.newInstance(service);
    }

    private static void say(String line) {
        System.out.println(line);
        System.out.flush();
    }
}

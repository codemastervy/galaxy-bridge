import android.content.ComponentName;
import android.os.IBinder;
import java.lang.reflect.Method;

/** Runs as the adb shell user: lists or calls the wallpaper service's set-component method. */
public class SetFace {
    public static void main(String[] args) throws Exception {
        Class<?> sm = Class.forName("android.os.ServiceManager");
        IBinder b = (IBinder) sm.getMethod("getService", String.class).invoke(null, "wallpaper");
        Object wm = Class.forName("android.app.IWallpaperManager$Stub").getMethod("asInterface", IBinder.class).invoke(null, b);
        if (args.length == 0) {
            for (Method m : wm.getClass().getMethods()) if (m.getName().toLowerCase().contains("component")) System.out.println(m);
            return;
        }
        ComponentName cn = ComponentName.unflattenFromString(args[0]);
        for (Method m : wm.getClass().getMethods()) {
            if (!m.getName().equals("setWallpaperComponent") || m.getParameterTypes().length != 1) continue;
            Class<?>[] p = m.getParameterTypes();
            Object[] values = new Object[p.length];
            values[0] = cn;
            for (int i = 1; i < p.length; i++) {
                if (p[i] == String.class) values[i] = "com.android.shell";
                else if (p[i] == int.class) values[i] = (i == p.length - 1) ? 0 : 1; // which = FLAG_SYSTEM, userId = 0
            }
            Object r = m.invoke(wm, values);
            System.out.println("called " + m.getName() + " -> " + r);
            return;
        }
        System.out.println("no setter found");
    }
}

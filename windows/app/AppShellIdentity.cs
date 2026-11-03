using System;
using System.IO;
using System.Runtime.InteropServices;

namespace AITaskMonitor.Windows
{
    public static class AppShellIdentity
    {
        public const string AppId = "imatrue.AITaskMonitor.Desktop";
        private static readonly Guid PropertyFormat = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        private struct PropertyKey
        {
            public Guid Format;
            public uint Id;
        }

        [StructLayout(LayoutKind.Explicit, Size = 24)]
        private struct PropertyValue
        {
            [FieldOffset(0)] public ushort Type;
            [FieldOffset(8)] public IntPtr Value;
        }

        [ComImport]
        [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPropertyStore
        {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int GetAt(uint index, out PropertyKey key);
            [PreserveSig] int GetValue(ref PropertyKey key, out PropertyValue value);
            [PreserveSig] int SetValue(ref PropertyKey key, ref PropertyValue value);
            [PreserveSig] int Commit();
        }

        [DllImport("shell32.dll", ExactSpelling = true)]
        private static extern int SHGetPropertyStoreForWindow(
            IntPtr window, ref Guid interfaceId,
            [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

        [DllImport("ole32.dll", ExactSpelling = true)]
        private static extern int PropVariantClear(ref PropertyValue value);

        private static IPropertyStore OpenStore(IntPtr window)
        {
            if (window == IntPtr.Zero) throw new ArgumentException("Window handle is required.", "window");
            Guid interfaceId = typeof(IPropertyStore).GUID;
            IPropertyStore store;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(window, ref interfaceId, out store));
            return store;
        }

        private static PropertyKey Key(uint id)
        {
            return new PropertyKey { Format = PropertyFormat, Id = id };
        }

        private static void SetString(IPropertyStore store, uint id, string text)
        {
            PropertyKey key = Key(id);
            PropertyValue value = new PropertyValue { Type = 31, Value = Marshal.StringToCoTaskMemUni(text) };
            try { Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value)); }
            finally { PropVariantClear(ref value); }
        }

        private static void SetEmpty(IPropertyStore store, uint id)
        {
            PropertyKey key = Key(id);
            PropertyValue value = new PropertyValue();
            Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value));
        }

        public static void Apply(IntPtr window, string iconPath, string launcherPath)
        {
            IPropertyStore store = OpenStore(window);
            try
            {
                if (!String.IsNullOrEmpty(iconPath) && File.Exists(iconPath)) SetString(store, 3, iconPath + ",0");
                if (!String.IsNullOrEmpty(launcherPath) && File.Exists(launcherPath))
                {
                    SetString(store, 2, "\"" + launcherPath + "\"");
                    SetString(store, 4, "AI task monitor");
                }
                SetString(store, 5, AppId);
            }
            finally { Marshal.ReleaseComObject(store); }
        }

        public static void Clear(IntPtr window)
        {
            IPropertyStore store = OpenStore(window);
            try
            {
                foreach (uint id in new uint[] { 2, 3, 4, 5 }) SetEmpty(store, id);
            }
            finally { Marshal.ReleaseComObject(store); }
        }

        public static string ReadProperty(IntPtr window, uint id)
        {
            if (id < 2 || id > 5) throw new ArgumentOutOfRangeException("id");
            IPropertyStore store = OpenStore(window);
            try
            {
                PropertyKey key = Key(id);
                PropertyValue value;
                Marshal.ThrowExceptionForHR(store.GetValue(ref key, out value));
                try { return value.Type == 31 && value.Value != IntPtr.Zero ? Marshal.PtrToStringUni(value.Value) : null; }
                finally { PropVariantClear(ref value); }
            }
            finally { Marshal.ReleaseComObject(store); }
        }
    }
}

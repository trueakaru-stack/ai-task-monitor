using AITaskMonitor.ExternalProviders;

// The copied reader uses the Framework serializer. This adapter is confined to
// the native assembly and does not change the installed Framework application.
namespace System.Web.Script.Serialization
{
    internal sealed class JavaScriptSerializer
    {
        private readonly SafeJsonDeserializer inner = new SafeJsonDeserializer
        {
            MaxJsonLength = 2097152,
            RecursionLimit = 100
        };

        public int MaxJsonLength { get { return inner.MaxJsonLength; } set { inner.MaxJsonLength = value; } }
        public int RecursionLimit { get { return inner.RecursionLimit; } set { inner.RecursionLimit = value; } }
        public object DeserializeObject(string json) { return inner.DeserializeObject(json); }
    }
}

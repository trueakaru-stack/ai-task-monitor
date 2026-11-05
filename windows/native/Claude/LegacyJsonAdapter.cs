using AITaskMonitor.ExternalProviders;

// The linked Framework channel uses JavaScriptSerializer. Keep the adapter in
// this isolated native assembly so the existing Framework source stays intact.
namespace System.Web.Script.Serialization
{
    internal sealed class JavaScriptSerializer
    {
        private readonly SafeJsonDeserializer inner = new SafeJsonDeserializer
        {
            MaxJsonLength = 2097152,
            RecursionLimit = 100
        };

        public int MaxJsonLength
        {
            get { return inner.MaxJsonLength; }
            set { inner.MaxJsonLength = value; }
        }

        public object DeserializeObject(string json) { return inner.DeserializeObject(json); }
    }
}

using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using AITaskMonitor.Prototype;

internal static class ContourChecks
{
    private static int points;
    private static double maximumError;

    public static void Run(string referencePath)
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(referencePath));
        foreach (JsonElement shape in document.RootElement.GetProperty("shapes").EnumerateArray())
        {
            JsonElement rect = shape.GetProperty("rect");
            double width = rect[2].GetDouble(), height = rect[3].GetDouble();
            var geometry = TabContour.Create(width, height, shape.GetProperty("radius").GetDouble()) as PathGeometry
                ?? throw new InvalidOperationException("Contour is not a WPF path.");
            JsonElement elements = shape.GetProperty("elements");
            if (geometry.Figures.Count != 1 || !geometry.Figures[0].IsClosed ||
                geometry.Figures[0].Segments.Count != elements.GetArrayLength() - 2)
                throw new InvalidOperationException("Contour segment count or closure differs.");
            PathFigure figure = geometry.Figures[0];
            AssertPoint(figure.StartPoint, elements[0].GetProperty("points")[0]);
            for (int i = 1; i < elements.GetArrayLength() - 1; i++)
            {
                JsonElement element = elements[i], referencePoints = element.GetProperty("points");
                PathSegment segment = figure.Segments[i - 1];
                if (element.GetProperty("type").GetString() == "line" && segment is LineSegment line)
                    AssertPoint(line.Point, referencePoints[0]);
                else if (element.GetProperty("type").GetString() == "cubic" && segment is BezierSegment cubic)
                {
                    AssertPoint(cubic.Point1, referencePoints[0]);
                    AssertPoint(cubic.Point2, referencePoints[1]);
                    AssertPoint(cubic.Point3, referencePoints[2]);
                }
                else throw new InvalidOperationException("Contour segment type differs.");
            }
        }
        if (points != 164) throw new InvalidOperationException("The expected four reference paths were not checked.");
        foreach (var (width, height, radius) in new[] { (30d, 42d, 14d), (25d, 34d, 10d), (520d, 41.5d, 14d), (168d, 35d, 10d) })
        {
            var fallback = (PathGeometry)TabContour.Create(width, height, radius);
            if (fallback.Figures[0].Segments.Count != 8) throw new InvalidOperationException("Unverified size did not use the old contour.");
        }
        Console.WriteLine($"C# WPF contour: {points} exported points; maximum coordinate error {maximumError:R}; fallback cases passed.");
    }

    private static void AssertPoint(Point actual, JsonElement expected)
    {
        double error = Math.Max(Math.Abs(actual.X - expected[0].GetDouble()), Math.Abs(actual.Y - expected[1].GetDouble()));
        maximumError = Math.Max(maximumError, error);
        points++;
        if (error > 1e-10) throw new InvalidOperationException($"Contour point differs by {error:R}.");
    }
}

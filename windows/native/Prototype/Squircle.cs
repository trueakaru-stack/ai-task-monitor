using System.Windows;
using System.Windows.Media;

namespace AITaskMonitor.Prototype;

// Port of Squircle-Geometry in the published Windows interface, revision 1c44076.
internal static class Squircle
{
    public static Geometry Create(double width, double height, double radius, double inset = 0)
    {
        double left = inset, top = inset;
        double right = Math.Max(left, width - inset), bottom = Math.Max(top, height - inset);
        double r = Math.Min(radius, Math.Min((right - left) / 2, (bottom - top) / 2));
        double k = r * 0.72;
        var figure = new PathFigure { StartPoint = new Point(left + r, top), IsClosed = true };
        figure.Segments.Add(new LineSegment(new Point(right - r, top), true));
        figure.Segments.Add(new BezierSegment(new Point(right - r + k, top), new Point(right, top + r - k), new Point(right, top + r), true));
        figure.Segments.Add(new LineSegment(new Point(right, bottom - r), true));
        figure.Segments.Add(new BezierSegment(new Point(right, bottom - r + k), new Point(right - r + k, bottom), new Point(right - r, bottom), true));
        figure.Segments.Add(new LineSegment(new Point(left + r, bottom), true));
        figure.Segments.Add(new BezierSegment(new Point(left + r - k, bottom), new Point(left, bottom - r + k), new Point(left, bottom - r), true));
        figure.Segments.Add(new LineSegment(new Point(left, top + r), true));
        figure.Segments.Add(new BezierSegment(new Point(left, top + r - k), new Point(left + r - k, top), new Point(left + r, top), true));
        return new PathGeometry(new[] { figure });
    }
}
